defmodule Liddr.Rides.Integrity.AcceptanceTelemetry do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride

  @eta_speed_m_per_second 7.0
  @minimum_eta_seconds 120

  def metadata_for_accept(%Ride{} = ride, driver_user_id) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^driver_user_id,
          select: dl
      )

    if is_nil(location) do
      %{}
    else
      distance_m =
        Geo.haversine_distance_m(location.lat, location.lng, ride.pickup_lat, ride.pickup_lng)
        |> round()

      promised_eta_s =
        distance_m
        |> Kernel./(@eta_speed_m_per_second)
        |> ceil()
        |> max(@minimum_eta_seconds)

      %{
        "driver_distance_to_pickup_m_at_accept" => distance_m,
        "promised_pickup_eta_s_at_accept" => promised_eta_s,
        "driver_location_captured_at_accept" => location.captured_at
      }
    end
  end
end
