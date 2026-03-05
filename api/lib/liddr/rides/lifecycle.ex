defmodule Liddr.Rides.Lifecycle do
  import Ecto.Query

  alias Ecto.Changeset
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Auth.Policy
  alias Liddr.Location
  alias Liddr.Repo
  alias Liddr.Rides.ActiveRides
  alias Liddr.Rides.DriverOfferLock
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.DriverLiveness
  alias Liddr.Rides.Events
  alias Liddr.Rides.Integrity.AcceptanceTelemetry
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.Subscriptions.PaymentUtils

  @assignable_ride_statuses ~w(requested offering)

  def list_driver_offers(driver_user_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    limit = resolve_history_limit(attrs)

    expired_offers =
      Repo.all(
        from o in RideOffer,
          where: o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at <= ^now
      )

    _ =
      Repo.update_all(
        from(o in RideOffer,
          where: o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at <= ^now
        ),
        set: [status: "expired", responded_at: now, updated_at: now]
      )

    record_offer_events!("offer_expired", expired_offers, now)
    record_offer_events!("offer_missed", expired_offers, now)
    DriverOfferLock.release_many(expired_offers, source: "driver_offer_list_expire")

    offers =
      Repo.all(
        from o in RideOffer,
          join: r in Ride,
          on: r.id == o.ride_id,
          join: d in Driver,
          on: d.user_id == o.driver_id,
          where:
            o.driver_id == ^driver_user_id and o.status == "offered" and o.expires_at > ^now and
              is_nil(d.current_ride_id),
          order_by: [desc: o.inserted_at],
          limit: ^limit,
          select: %{offer: o, ride: r}
      )

    {:ok, offers}
  end

  def accept_offer(driver_user_id, offer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        offer = fetch_offer_for_update!(offer_id)
        ensure_offer_belongs_to_driver!(offer, driver_user_id)
        ensure_offer_open!(offer, now)
        driver = ensure_driver_eligible_for_accept!(driver_user_id, now)
        ride = fetch_ride_for_update!(offer.ride_id)
        ensure_ride_assignable!(ride)

        competing_ride_offers =
          Repo.all(
            from(o in RideOffer,
              where: o.ride_id == ^ride.id and o.id != ^offer.id and o.status == "offered"
            )
          )

        competing_driver_offers =
          Repo.all(
            from(o in RideOffer,
              where:
                o.driver_id == ^driver_user_id and o.ride_id != ^ride.id and o.status == "offered"
            )
          )

        _ =
          Repo.update_all(
            from(o in RideOffer,
              where: o.ride_id == ^ride.id and o.id != ^offer.id and o.status == "offered"
            ),
            set: [status: "withdrawn", responded_at: now, updated_at: now]
          )

        _ =
          Repo.update_all(
            from(o in RideOffer,
              where:
                o.driver_id == ^driver_user_id and o.ride_id != ^ride.id and o.status == "offered"
            ),
            set: [status: "withdrawn", responded_at: now, updated_at: now]
          )

        accepted_offer =
          offer
          |> RideOffer.create_changeset(%{"status" => "accepted", "responded_at" => now})
          |> Repo.update()
          |> unwrap_or_rollback()

        ride_metadata =
          ride.metadata
          |> normalize_ride_metadata()
          |> Map.merge(AcceptanceTelemetry.metadata_for_accept(ride, driver_user_id))

        updated_ride =
          ride
          |> Ride.create_changeset(%{
            "status" => "accepted",
            "driver_id" => driver_user_id,
            "accepted_at" => now,
            "metadata" => ride_metadata
          })
          |> Repo.update()
          |> unwrap_or_rollback()

        _updated_driver =
          driver
          |> Driver.create_changeset(%{
            "current_ride_id" => ride.id,
            "dispatch_status" => "heading_to_pickup",
            "is_available" => false,
            "last_seen_at" => now
          })
          |> Repo.update()
          |> unwrap_or_rollback()

        _ =
          Events.record_event(ride.id, "ride_accepted", now,
            actor_user_id: driver_user_id,
            payload: %{"offer_id" => accepted_offer.id}
          )
          |> unwrap_or_rollback()

        new_driver_found_payload =
          build_new_driver_found_payload(ride.metadata, driver_user_id, accepted_offer.id)

        _ =
          maybe_record_new_driver_found_event(
            ride.id,
            driver_user_id,
            new_driver_found_payload,
            now
          )
          |> unwrap_or_rollback()

        %{
          ride: updated_ride,
          offer: accepted_offer,
          competing_ride_offers: competing_ride_offers,
          competing_driver_offers: competing_driver_offers,
          new_driver_found_payload: new_driver_found_payload
        }
      end)
      |> unwrap_transaction_result()
      |> normalize_accept_error()

    case result do
      {:ok,
       %{
         ride: ride,
         offer: accepted_offer,
         competing_ride_offers: competing_ride_offers,
         competing_driver_offers: competing_driver_offers,
         new_driver_found_payload: new_driver_found_payload
       } = payload} ->
        _ = Location.remove_driver_from_supply(driver_user_id)

        DriverOfferLock.release_many(
          [
            accepted_offer | competing_ride_offers ++ competing_driver_offers
          ],
          source: "offer_accept"
        )

        Realtime.broadcast_ride_assigned(ride, accepted_offer)
        maybe_broadcast_new_driver_found(ride, new_driver_found_payload)

        Enum.each(
          competing_ride_offers,
          &Realtime.broadcast_offer_withdrawn(ride.id, &1, "ride_assigned")
        )

        Enum.each(
          competing_driver_offers,
          &Realtime.broadcast_offer_withdrawn(&1.ride_id, &1, "driver_busy")
        )

        Dispatcher.stop(ride.id)
        {:ok, Map.take(payload, [:ride, :offer])}

      _ ->
        result
    end
  end

  def reject_offer(driver_user_id, offer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        offer = fetch_offer_for_update!(offer_id)
        ensure_offer_belongs_to_driver!(offer, driver_user_id)
        ensure_offer_open!(offer, now)
        ride = fetch_ride_for_update!(offer.ride_id)

        rejected_offer =
          offer
          |> RideOffer.create_changeset(%{"status" => "rejected", "responded_at" => now})
          |> Repo.update()
          |> unwrap_or_rollback()

        _ =
          Events.record_event(ride.id, "offer_rejected", now,
            actor_user_id: driver_user_id,
            payload: %{"offer_id" => rejected_offer.id}
          )
          |> unwrap_or_rollback()

        %{ride: ride, offer: rejected_offer}
      end)
      |> unwrap_transaction_result()

    case result do
      {:ok, %{ride: ride, offer: rejected_offer} = payload} ->
        DriverOfferLock.release_many([rejected_offer], source: "offer_reject")
        Realtime.broadcast_offer_withdrawn(ride.id, rejected_offer, "driver_rejected")
        _ = Dispatcher.ensure_started(ride.id)
        :ok = Dispatcher.dispatch_now(ride.id)
        {:ok, payload}

      _ ->
        result
    end
  end

  defp fetch_offer_for_update!(offer_id) do
    parsed_offer_id = parse_positive_integer(offer_id) || Repo.rollback(:ride_offer_not_found)

    Repo.one(
      from o in RideOffer,
        where: o.id == ^parsed_offer_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:ride_offer_not_found)
  end

  defp fetch_ride_for_update!(ride_id) do
    Repo.one(
      from r in Ride,
        where: r.id == ^ride_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:ride_not_found)
  end

  defp ensure_offer_belongs_to_driver!(offer, driver_user_id) do
    if offer.driver_id == driver_user_id, do: :ok, else: Repo.rollback(:offer_not_for_driver)
  end

  defp ensure_offer_open!(offer, now) do
    cond do
      offer.status != "offered" ->
        Repo.rollback(:ride_offer_not_open)

      DateTime.compare(offer.expires_at, now) != :gt ->
        _ =
          offer
          |> RideOffer.create_changeset(%{"status" => "expired", "responded_at" => now})
          |> Repo.update()

        Repo.rollback(:ride_offer_expired)

      true ->
        :ok
    end
  end

  defp ensure_ride_assignable!(ride) do
    if ride.status in @assignable_ride_statuses and is_nil(ride.driver_id) do
      :ok
    else
      Repo.rollback(:ride_not_assignable)
    end
  end

  defp ensure_driver_eligible_for_accept!(driver_user_id, now) do
    user = Repo.get(User, driver_user_id) || Repo.rollback(:user_not_found)

    case Policy.ensure_user_can_authenticate(user) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    driver =
      Repo.one(
        from d in Driver,
          where: d.user_id == ^driver_user_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:driver_profile_not_found)

    cond do
      driver.account_status != "active" ->
        Repo.rollback(:driver_account_not_active)

      driver.verification_status != "approved" ->
        Repo.rollback(:driver_not_verified)

      driver.subscription_status != "active" ->
        Repo.rollback(:driver_subscription_not_active)

      not is_nil(driver.current_ride_id) ->
        Repo.rollback(:driver_has_active_ride)

      ActiveRides.driver_has_active_ride?(driver_user_id) ->
        Repo.rollback(:driver_has_active_ride)

      driver.is_available != true ->
        Repo.rollback(:driver_not_available)

      not DriverLiveness.accept_allowed?(DriverLiveness.snapshot(driver, now)) ->
        Repo.rollback(:driver_presence_unhealthy)

      true ->
        driver
    end
  end

  defp resolve_history_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer()
    |> clamp(20, 100)
  end

  defp clamp(nil, default, _max), do: default
  defp clamp(value, _default, max) when value > max, do: max
  defp clamp(value, _default, _max), do: value

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp normalize_ride_metadata(%{} = metadata), do: metadata
  defp normalize_ride_metadata(_metadata), do: %{}

  defp record_offer_events!(_event_type, [], _occurred_at), do: :ok

  defp record_offer_events!(event_type, offers, occurred_at) do
    Enum.each(offers, fn offer ->
      payload = %{"offer_id" => offer.id, "driver_id" => offer.driver_id}

      _ =
        Events.record_event(offer.ride_id, event_type, occurred_at,
          actor_user_id: offer.driver_id,
          payload: payload
        )
        |> unwrap_or_rollback()
    end)
  end

  defp unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp normalize_accept_error({:error, %Changeset{} = changeset}) do
    if active_driver_conflict_changeset?(changeset),
      do: {:error, :driver_has_active_ride},
      else: {:error, changeset}
  end

  defp normalize_accept_error(result), do: result

  defp active_driver_conflict_changeset?(changeset) do
    changeset.errors
    |> Keyword.get_values(:driver_id)
    |> Enum.any?(fn {_message, opts} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "rides_unique_active_driver_idx"
    end)
  end

  defp build_new_driver_found_payload(%{} = metadata, new_driver_id, offer_id) do
    reassign_count = Map.get(metadata, "reassign_count", 0)

    if is_integer(reassign_count) and reassign_count > 0 do
      %{
        "reassign_count" => reassign_count,
        "previous_driver_id" => Map.get(metadata, "last_reassign_driver_id"),
        "new_driver_id" => new_driver_id,
        "offer_id" => offer_id,
        "recommendation_reason_code" => Map.get(metadata, "last_reassign_reason_code")
      }
    else
      nil
    end
  end

  defp build_new_driver_found_payload(_metadata, _new_driver_id, _offer_id), do: nil

  defp maybe_record_new_driver_found_event(_ride_id, _driver_user_id, nil, _now), do: {:ok, nil}

  defp maybe_record_new_driver_found_event(ride_id, driver_user_id, payload, now) do
    Events.record_event(ride_id, "new_driver_found", now,
      actor_user_id: driver_user_id,
      payload: payload
    )
  end

  defp maybe_broadcast_new_driver_found(_ride, nil), do: :ok

  defp maybe_broadcast_new_driver_found(ride, payload) do
    Realtime.broadcast_new_driver_found(ride, %{
      previous_driver_id: payload["previous_driver_id"],
      new_driver_id: payload["new_driver_id"],
      reassign_count: payload["reassign_count"],
      recommendation_reason_code: payload["recommendation_reason_code"],
      offer_id: payload["offer_id"]
    })
  end
end
