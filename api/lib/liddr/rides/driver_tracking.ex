defmodule Liddr.Rides.DriverTracking do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRideMember
  alias LiddrWeb.Endpoint

  @event "driver_location_updated"
  @active_statuses ~w(accepted driver_arriving arrived in_progress)
  @ended_member_statuses ~w(dropped_off cancelled no_show)
  @max_speed_kmh 400

  def event, do: @event

  def publish(%{current_ride_id: ride_id, user_id: driver_id}, lat, lng, captured_at, attrs)
      when is_integer(ride_id) do
    with %Ride{} = ride <- fetch_active_ride(ride_id, driver_id) do
      payload =
        location_payload(
          ride.id,
          lat,
          lng,
          attr_value(attrs, :bearing),
          attr_value(attrs, :speed_kmh),
          captured_at
        )

      Endpoint.broadcast(
        "ride:#{ride.id}",
        @event,
        Map.put(payload, :visible_user_ids, visible_user_ids(ride))
      )
    end

    :ok
  end

  def publish(_driver, _lat, _lng, _captured_at, _attrs), do: :ok

  def latest_for_user(%Ride{status: status, driver_id: driver_id} = ride, user_id)
      when status in @active_statuses and is_integer(driver_id) do
    with true <- user_id in visible_user_ids(ride),
         %DriverLocation{} = location <- Repo.get(DriverLocation, driver_id) do
      metadata = location.metadata || %{}

      location_payload(
        ride.id,
        Decimal.to_float(location.lat),
        Decimal.to_float(location.lng),
        Map.get(metadata, "bearing"),
        Map.get(metadata, "speed_kmh"),
        location.captured_at
      )
    else
      _ -> nil
    end
  end

  def latest_for_user(_ride, _user_id), do: nil

  def visible_user_ids(%Ride{product_type: "shared"} = ride) do
    member_ids =
      Repo.all(
        from m in SharedRideMember,
          where: m.ride_id == ^ride.id and m.status not in ^@ended_member_statuses,
          select: m.rider_user_id
      )

    [ride.driver_id | member_ids]
  end

  def visible_user_ids(%Ride{} = ride), do: [ride.driver_id, ride.rider_id]

  defp fetch_active_ride(ride_id, driver_id) do
    Repo.one(
      from r in Ride,
        where: r.id == ^ride_id and r.driver_id == ^driver_id and r.status in ^@active_statuses,
        select: struct(r, [:id, :status, :product_type, :driver_id, :rider_id])
    )
  end

  defp location_payload(ride_id, lat, lng, bearing, speed_kmh, captured_at) do
    %{
      ride_id: ride_id,
      lat: lat,
      lng: lng,
      bearing: bounded_number(bearing, 360),
      speed_kmh: bounded_number(speed_kmh, @max_speed_kmh),
      captured_at: captured_at
    }
  end

  defp bounded_number(value, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> bounded_number(parsed, max)
      _ -> nil
    end
  end

  defp bounded_number(value, max) when is_number(value) and value >= 0 and value <= max,
    do: value * 1.0

  defp bounded_number(_value, _max), do: nil

  defp attr_value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
