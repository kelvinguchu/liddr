defmodule Liddr.Rides.PickupWatchdogSummary do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.PickupWatchdog
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideEvent

  @default_limit 50
  @max_limit 200
  @default_window_seconds 86_400

  def fetch(attrs \\ %{}) do
    with {:ok, since} <- parse_since(attrs),
         {:ok, limit} <- parse_limit(attrs) do
      events =
        Repo.all(
          from e in RideEvent,
            join: r in Ride,
            on: r.id == e.ride_id,
            where: e.event_type in ^event_types() and e.occurred_at >= ^since,
            order_by: [desc: e.occurred_at, desc: e.id],
            limit: ^limit,
            select: %{
              event: e,
              ride_status: r.status,
              rider_id: r.rider_id,
              driver_id: r.driver_id,
              vehicle_category_id: r.vehicle_category_id
            }
        )

      {:ok,
       %{
         since: since,
         limit: limit,
         counts: %{
           total: length(events),
           auto_reassigned:
             Enum.count(events, fn row ->
               row.event.event_type == PickupWatchdog.auto_reassign_event_type()
             end),
           auto_cancelled:
             Enum.count(events, fn row ->
               row.event.event_type == PickupWatchdog.auto_cancel_event_type()
             end)
         },
         recent_actions: Enum.map(events, &action_payload/1)
       }}
    end
  end

  defp event_types do
    [PickupWatchdog.auto_reassign_event_type(), PickupWatchdog.auto_cancel_event_type()]
  end

  defp action_payload(row) do
    payload = if is_map(row.event.payload), do: row.event.payload, else: %{}
    pickup_health = Map.get(payload, "pickup_health", %{})

    %{
      ride_id: row.event.ride_id,
      event_type: row.event.event_type,
      occurred_at: row.event.occurred_at,
      ride_status: row.ride_status,
      rider_id: row.rider_id,
      driver_id: row.driver_id,
      vehicle_category_id: row.vehicle_category_id,
      action_reason_code: Map.get(payload, "action_reason_code"),
      recommendation_reason_code: Map.get(pickup_health, "recommendation_reason_code"),
      flags: Map.get(pickup_health, "flags", %{}),
      signals: Map.get(pickup_health, "signals", %{}),
      timeouts: Map.get(pickup_health, "timeouts", %{})
    }
  end

  defp parse_since(attrs) do
    default_since =
      DateTime.utc_now()
      |> DateTime.truncate(:microsecond)
      |> DateTime.add(-@default_window_seconds, :second)

    case get_value(attrs, :since) do
      nil ->
        {:ok, default_since}

      %DateTime{} = dt ->
        {:ok, DateTime.truncate(dt, :microsecond)}

      binary when is_binary(binary) ->
        case DateTime.from_iso8601(String.trim(binary)) do
          {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :microsecond)}
          _ -> {:error, :invalid_since}
        end

      _ ->
        {:error, :invalid_since}
    end
  end

  defp parse_limit(attrs) do
    case get_value(attrs, :limit) do
      nil ->
        {:ok, @default_limit}

      value when is_integer(value) and value >= 1 and value <= @max_limit ->
        {:ok, value}

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, ""} when parsed >= 1 and parsed <= @max_limit -> {:ok, parsed}
          _ -> {:error, :invalid_pickup_watchdog_limit}
        end

      _ ->
        {:error, :invalid_pickup_watchdog_limit}
    end
  end

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil
end
