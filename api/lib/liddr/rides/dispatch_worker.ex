defmodule Liddr.Rides.DispatchWorker do
  use GenServer

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.CandidateSelection
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Events
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.Rides.VehicleCategory

  @default_offer_limit 3
  @default_offer_ttl_seconds 15
  @max_offer_limit 10
  @max_offer_ttl_seconds 120
  @minimum_loop_delay_ms 500
  @retry_delay_ms 10_000
  @radius_multipliers [1.0, 1.5, 2.0, 3.0]

  def child_spec(opts) do
    ride_id = Keyword.fetch!(opts, :ride_id)

    %{
      id: {__MODULE__, ride_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    ride_id = Keyword.fetch!(opts, :ride_id)
    name = {:via, Registry, {Liddr.Rides.DispatchRegistry, ride_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      ride_id: Keyword.fetch!(opts, :ride_id),
      offer_limit:
        clamp_int(Keyword.get(opts, :offer_limit), @default_offer_limit, @max_offer_limit),
      offer_ttl_seconds:
        clamp_int(
          Keyword.get(opts, :offer_ttl_seconds),
          @default_offer_ttl_seconds,
          @max_offer_ttl_seconds
        ),
      wave_index: 0,
      timer_ref: nil
    }

    {:ok, schedule_dispatch(state, 0)}
  end

  @impl true
  def handle_info(:dispatch_cycle, state) do
    case run_and_schedule(state) do
      {:stop, reason, next_state} -> {:stop, reason, next_state}
      {:noreply, next_state} -> {:noreply, next_state}
    end
  end

  @impl true
  def handle_call(:dispatch_now, _from, state) do
    case run_and_schedule(state) do
      {:stop, reason, next_state} -> {:stop, reason, :ok, next_state}
      {:noreply, next_state} -> {:reply, :ok, next_state}
    end
  end

  defp run_and_schedule(state) do
    case run_cycle(state) do
      {:stop, _reason} ->
        {:stop, :normal, cancel_dispatch_timer(state)}

      {:reschedule, delay_ms, next_wave_index} ->
        {:noreply,
         state
         |> Map.put(:wave_index, next_wave_index)
         |> schedule_dispatch(delay_ms)}
    end
  end

  defp run_cycle(state) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.transaction(fn -> dispatch_transaction(state, now) end) do
      {:ok, {result, events}} ->
        publish_events(events)
        result

      {:error, _reason} ->
        {:reschedule, @retry_delay_ms, state.wave_index}
    end
  end

  defp dispatch_transaction(state, now) do
    ride =
      Repo.one(
        from r in Ride,
          where: r.id == ^state.ride_id,
          lock: "FOR UPDATE"
      )

    cond do
      is_nil(ride) ->
        {{:stop, :ride_not_found}, []}

      ride.status in ["accepted", "cancelled", "completed"] ->
        {{:stop, :ride_finalized}, []}

      true ->
        expired_offers = expire_stale_offers!(ride.id, now)
        expired_events = Enum.map(expired_offers, &{:offer_expired, ride, &1})

        case earliest_open_offer_expiry(ride.id, now) do
          %DateTime{} = expiry ->
            {{:reschedule, delay_until(expiry, now), state.wave_index}, expired_events}

          nil ->
            {decision, created_events} = dispatch_next_wave(state, ride, now)
            {decision, expired_events ++ created_events}
        end
    end
  end

  defp dispatch_next_wave(state, ride, now) do
    category = Repo.get(VehicleCategory, ride.vehicle_category_id)

    if is_nil(category) do
      {{:stop, :vehicle_category_not_found}, []}
    else
      pickup = %{lat: decimal_to_float(ride.pickup_lat), lng: decimal_to_float(ride.pickup_lng)}
      existing_driver_ids = existing_offer_driver_ids(ride.id)
      radius_multiplier = radius_multiplier_for_wave(state.wave_index)

      candidate_ids =
        CandidateSelection.list_eligible_driver_ids(category, pickup, state.offer_limit,
          radius_multiplier: radius_multiplier,
          exclude_driver_ids: existing_driver_ids
        )

      if candidate_ids == [] do
        {{:reschedule, @retry_delay_ms, next_wave_index(state.wave_index)}, []}
      else
        offers = create_offers!(ride.id, candidate_ids, now, state.offer_ttl_seconds)
        record_offer_events!(ride.id, "offer_created", offers, now)
        created_events = Enum.map(offers, &{:offer_created, ride, &1})

        if ride.status == "requested" do
          _ = ride |> Ride.create_changeset(%{"status" => "offering"}) |> Repo.update()
        end

        next_expiry = DateTime.add(now, state.offer_ttl_seconds, :second)

        {{:reschedule, delay_until(next_expiry, now), next_wave_index(state.wave_index)},
         created_events}
      end
    end
  end

  defp create_offers!(ride_id, driver_ids, now, offer_ttl_seconds) do
    expires_at = DateTime.add(now, offer_ttl_seconds, :second)

    lock_result =
      DriverOfferLock.acquire_many(driver_ids, ride_id, offer_ttl_seconds,
        source: "dispatch_wave"
      )

    selected_driver_ids = normalize_driver_ids(lock_result.selected_driver_ids)
    locked_driver_ids = normalize_driver_ids(lock_result.locked_driver_ids)

    if selected_driver_ids == [] do
      []
    else
      rows =
        Enum.map(selected_driver_ids, fn driver_id ->
          %{
            ride_id: ride_id,
            driver_id: driver_id,
            status: "offered",
            offered_at: now,
            expires_at: expires_at,
            inserted_at: now,
            updated_at: now
          }
        end)

      {_, returning_rows} =
        Repo.insert_all(RideOffer, rows,
          on_conflict: :nothing,
          conflict_target: [:ride_id, :driver_id],
          returning: [:id, :ride_id, :driver_id, :status, :offered_at, :expires_at, :inserted_at]
        )

      offers =
        returning_rows
        |> normalize_rows()
        |> Enum.map(fn
          %RideOffer{} = offer -> offer
          row when is_map(row) -> struct(RideOffer, row)
        end)

      inserted_driver_ids = offers |> Enum.map(& &1.driver_id) |> MapSet.new()

      locked_driver_ids
      |> Enum.reject(&MapSet.member?(inserted_driver_ids, &1))
      |> Enum.map(&{&1, ride_id})
      |> DriverOfferLock.release_many(source: "dispatch_insert_conflict")

      offers
    end
  end

  defp expire_stale_offers!(ride_id, now) do
    expired_offers =
      Repo.all(
        from(o in RideOffer,
          where: o.ride_id == ^ride_id and o.status == "offered" and o.expires_at <= ^now
        )
      )

    if expired_offers != [] do
      _ =
        Repo.update_all(
          from(o in RideOffer,
            where: o.ride_id == ^ride_id and o.status == "offered" and o.expires_at <= ^now
          ),
          set: [status: "expired", responded_at: now, updated_at: now]
        )

      record_offer_events!(ride_id, "offer_expired", expired_offers, now)
      record_offer_events!(ride_id, "offer_missed", expired_offers, now)
      DriverOfferLock.release_many(expired_offers, source: "dispatch_expire")
    end

    Enum.map(expired_offers, fn offer ->
      %{offer | status: "expired", responded_at: now}
    end)
  end

  defp earliest_open_offer_expiry(ride_id, now) do
    Repo.one(
      from o in RideOffer,
        where: o.ride_id == ^ride_id and o.status == "offered" and o.expires_at > ^now,
        select: min(o.expires_at)
    )
  end

  defp existing_offer_driver_ids(ride_id) do
    Repo.all(
      from o in RideOffer,
        where: o.ride_id == ^ride_id,
        select: o.driver_id
    )
  end

  defp schedule_dispatch(state, delay_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :dispatch_cycle, max(delay_ms, 0))
    %{state | timer_ref: timer_ref}
  end

  defp cancel_dispatch_timer(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp next_wave_index(wave_index) do
    max_wave_index = length(@radius_multipliers) - 1
    min(wave_index + 1, max_wave_index)
  end

  defp radius_multiplier_for_wave(wave_index), do: Enum.at(@radius_multipliers, wave_index, 3.0)

  defp delay_until(expiry, now),
    do: max(DateTime.diff(expiry, now, :millisecond), @minimum_loop_delay_ms)

  defp clamp_int(value, _default, max) when is_integer(value) and value > 0 and value <= max,
    do: value

  defp clamp_int(_value, default, _max), do: default

  defp decimal_to_float(%D{} = value), do: D.to_float(value)
  defp decimal_to_float(value) when is_float(value), do: value
  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
  defp decimal_to_float(_value), do: 0.0

  defp normalize_rows(nil), do: []
  defp normalize_rows(rows) when is_list(rows), do: rows
  defp normalize_rows(row), do: [row]

  defp normalize_driver_ids(driver_ids) do
    driver_ids
    |> List.wrap()
    |> Enum.flat_map(fn
      driver_id when is_integer(driver_id) and driver_id > 0 ->
        [driver_id]

      %RideOffer{driver_id: driver_id} when is_integer(driver_id) and driver_id > 0 ->
        [driver_id]

      %{"driver_id" => driver_id} when is_integer(driver_id) and driver_id > 0 ->
        [driver_id]

      %{driver_id: driver_id} when is_integer(driver_id) and driver_id > 0 ->
        [driver_id]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp publish_events(events) do
    Enum.each(events, fn
      {:offer_created, ride, offer} ->
        Realtime.broadcast_offer_created(ride, offer)

      {:offer_expired, ride, offer} ->
        Realtime.broadcast_offer_expired(ride, offer)

      _ ->
        :ok
    end)
  end

  defp record_offer_events!(ride_id, event_type, offers, occurred_at) do
    Enum.each(offers, fn offer ->
      payload = %{"offer_id" => offer.id, "driver_id" => offer.driver_id}

      case Events.record_event(ride_id, event_type, occurred_at, payload: payload) do
        {:ok, _event} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
