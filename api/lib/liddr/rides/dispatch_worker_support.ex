defmodule Liddr.Rides.DispatchWorkerSupport do
  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.RideOffer

  def decimal_to_float(%D{} = value), do: D.to_float(value)
  def decimal_to_float(value) when is_float(value), do: value
  def decimal_to_float(value) when is_integer(value), do: value * 1.0
  def decimal_to_float(_value), do: 0.0

  def normalize_rows(nil), do: []
  def normalize_rows(rows) when is_list(rows), do: rows
  def normalize_rows(row), do: [row]

  def normalize_driver_ids(driver_ids) do
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

  def publish_events(events) do
    Enum.each(events, fn
      {:offer_created, ride, offer} ->
        Realtime.broadcast_offer_created(ride, offer)

      {:offer_expired, ride, offer} ->
        Realtime.broadcast_offer_expired(ride, offer)

      _ ->
        :ok
    end)
  end

  def record_offer_events!(ride_id, event_type, offers, occurred_at) do
    Enum.each(offers, fn offer ->
      payload = %{"offer_id" => offer.id, "driver_id" => offer.driver_id}

      case Events.record_event(ride_id, event_type, occurred_at, payload: payload) do
        {:ok, _event} -> :ok
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
