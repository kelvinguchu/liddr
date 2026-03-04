defmodule Liddr.Rides.Timeline do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.Ride
  alias Liddr.Subscriptions.PaymentUtils

  @default_incident_limit 50
  @max_incident_limit 200
  @incident_event_types ~w(
    ride_cancelled
    ride_integrity_evaluated
    ride_reassign_requested
    offer_expired
    offer_missed
    offer_withdrawn
    driver_arriving
    driver_arrived
    trip_started
    ride_completed
  )

  def get_ride_for_user(user_id, ride_id) do
    with parsed_ride_id when not is_nil(parsed_ride_id) <- parse_positive_integer(ride_id),
         %Ride{} = ride <- fetch_accessible_ride(user_id, parsed_ride_id) do
      {:ok, ride}
    else
      _ -> {:error, :ride_not_accessible}
    end
  end

  def list_events_for_user(user_id, ride_id, attrs \\ %{}) do
    with {:ok, ride} <- get_ride_for_user(user_id, ride_id),
         {:ok, timeline} <- Events.list_for_ride(ride.id, attrs) do
      {:ok, Map.put(timeline, :ride, ride)}
    end
  end

  def list_incidents_for_user(user_id, ride_id, attrs \\ %{}) do
    with {:ok, ride} <- get_ride_for_user(user_id, ride_id) do
      limit = resolve_incident_limit(attrs)
      since = parse_since(attrs)

      query =
        from e in RideEvent,
          where: e.ride_id == ^ride.id and e.event_type in ^@incident_event_types,
          order_by: [asc: e.occurred_at, asc: e.id],
          limit: ^limit

      query =
        if since do
          from e in query, where: e.occurred_at > ^since
        else
          query
        end

      incidents = Repo.all(query)

      {:ok,
       %{
         ride: ride,
         incidents: incidents,
         summary: %{
           total: length(incidents),
           by_event_type: Enum.frequencies_by(incidents, & &1.event_type)
         },
         next_since: next_since(incidents)
       }}
    end
  end

  defp fetch_accessible_ride(user_id, ride_id) do
    Repo.one(
      from r in Ride,
        where: r.id == ^ride_id and (r.rider_id == ^user_id or r.driver_id == ^user_id),
        limit: 1
    )
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp resolve_incident_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> parse_positive_integer()
    |> case do
      nil -> @default_incident_limit
      n when n > @max_incident_limit -> @max_incident_limit
      n -> n
    end
  end

  defp parse_since(attrs) do
    attrs
    |> PaymentUtils.get_value(:since)
    |> parse_datetime()
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp next_since([]), do: nil
  defp next_since(events), do: events |> List.last() |> Map.get(:occurred_at)
end
