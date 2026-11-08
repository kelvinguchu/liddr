defmodule LiddrWeb.RideControllerReadActions do
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Rides
  alias LiddrWeb.RideControllerErrors
  alias LiddrWeb.RideSerializer

  def show(conn, user_id, ride_id) do
    case Rides.get_ride_for_user(user_id, ride_id) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> RideControllerErrors.render(conn, reason)
    end
  end

  def events(conn, user_id, ride_id, params) do
    case Rides.list_events_for_user(user_id, ride_id, params) do
      {:ok, %{ride: ride, events: events, next_since: next_since}} ->
        json(conn, %{
          data:
            Map.merge(
              %{ride: RideSerializer.ride_payload(ride)},
              RideSerializer.events_payload(events, next_since)
            )
        })

      {:error, reason} ->
        RideControllerErrors.render(conn, reason)
    end
  end

  def incidents(conn, user_id, ride_id, params) do
    case Rides.list_incidents_for_user(user_id, ride_id, params) do
      {:ok, %{ride: ride, incidents: incidents, summary: summary, next_since: next_since}} ->
        json(conn, %{
          data: %{
            ride: RideSerializer.ride_payload(ride),
            incidents: Enum.map(incidents, &RideSerializer.event_payload/1),
            summary: summary,
            next_since: next_since
          }
        })

      {:error, reason} ->
        RideControllerErrors.render(conn, reason)
    end
  end

  def current_status(conn, user_id, ride_id) do
    case Rides.current_trip_status_for_user(user_id, ride_id) do
      {:ok, %{ride: ride, current_trip_status: current_trip_status}} ->
        json(conn, %{
          data: %{
            ride: RideSerializer.ride_payload(ride),
            current_trip_status: current_trip_status
          }
        })

      {:error, reason} ->
        RideControllerErrors.render(conn, reason)
    end
  end
end
