defmodule Liddr.Rides.Execution.Geofence do
  import Ecto.Query

  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Execution.GeoPolicy
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride

  def ensure_arrival!(%Ride{} = ride, driver_user_id, now) do
    if GeoPolicy.require_geofence_on_arrive?() do
      ensure_distance!(
        ride,
        driver_user_id,
        ride.pickup_lat,
        ride.pickup_lng,
        GeoPolicy.pickup_arrival_radius_m(),
        :driver_too_far_from_pickup,
        "distance_to_pickup_m",
        now
      )
    else
      %{distance_m: nil, payload: %{}}
    end
  end

  def ensure_completion!(%Ride{} = ride, driver_user_id, now) do
    if GeoPolicy.require_geofence_on_complete?() do
      ensure_distance!(
        ride,
        driver_user_id,
        ride.dropoff_lat,
        ride.dropoff_lng,
        GeoPolicy.dropoff_completion_radius_m(),
        :driver_too_far_from_dropoff,
        "distance_to_dropoff_m",
        now
      )
    else
      %{distance_m: nil, payload: %{}}
    end
  end

  defp ensure_distance!(
         %Ride{},
         driver_user_id,
         target_lat,
         target_lng,
         radius_m,
         distance_error,
         distance_payload_key,
         now
       ) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^driver_user_id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:driver_location_not_found)

    freshness_seconds = DateTime.diff(now, location.captured_at, :second)

    if freshness_seconds > GeoPolicy.location_freshness_seconds() do
      Repo.rollback(:driver_location_stale)
    end

    distance_m =
      Geo.haversine_distance_m(
        location.lat,
        location.lng,
        target_lat,
        target_lng
      )

    distance_m_int = trunc(Float.round(distance_m))

    if distance_m_int > radius_m do
      Repo.rollback(distance_error)
    end

    %{
      distance_m: distance_m_int,
      payload: %{
        "driver_lat" => Geo.to_float(location.lat),
        "driver_lng" => Geo.to_float(location.lng),
        "radius_m" => radius_m,
        "location_captured_at" => location.captured_at,
        distance_payload_key => distance_m_int
      }
    }
  end
end
