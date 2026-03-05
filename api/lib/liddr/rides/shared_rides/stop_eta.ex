defmodule Liddr.Rides.SharedRides.StopEta do
  @moduledoc false

  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride

  @defaults %{
    google_enabled: false,
    fallback_speed_kph: 28.0,
    min_leg_seconds: 60,
    max_leg_seconds: 7_200
  }

  def annotate(stops, %Ride{} = ride, now) when is_list(stops) and is_struct(now, DateTime) do
    start_point = {Geo.to_float(ride.pickup_lat), Geo.to_float(ride.pickup_lng)}
    annotate_from(stops, start_point, now)
  end

  def annotate_from(stops, {start_lat, start_lng}, now)
      when is_list(stops) and is_struct(now, DateTime) do
    start_point = {Geo.to_float(start_lat), Geo.to_float(start_lng)}
    do_annotate(stops, start_point, now, [])
  end

  defp do_annotate([], _from_point, _current_eta, acc), do: Enum.reverse(acc)

  defp do_annotate([stop | rest], from_point, current_eta, acc) do
    to_point = {Geo.to_float(stop.lat), Geo.to_float(stop.lng)}
    {duration_s, source} = estimate_leg(from_point, to_point, current_eta)
    leg_eta = DateTime.add(current_eta, duration_s, :second)

    annotated =
      stop
      |> Map.put(:eta_at, leg_eta)
      |> Map.put(:metadata, %{"eta_source" => source, "eta_leg_seconds" => duration_s})

    do_annotate(rest, to_point, leg_eta, [annotated | acc])
  end

  defp estimate_leg({from_lat, from_lng}, {to_lat, to_lng}, departure_time) do
    if google_enabled?() do
      case routes_client().compute_route(%{
             origin: %{lat: from_lat, lng: from_lng},
             destination: %{lat: to_lat, lng: to_lng},
             travel_mode: "DRIVE",
             routing_preference: "TRAFFIC_AWARE_OPTIMAL",
             departure_time: departure_time
           }) do
        {:ok, %{duration_s: duration_s}} -> {clamp_duration(duration_s), "google_routes"}
        _ -> {fallback_leg_seconds(from_lat, from_lng, to_lat, to_lng), "fallback_haversine"}
      end
    else
      {fallback_leg_seconds(from_lat, from_lng, to_lat, to_lng), "fallback_haversine"}
    end
  end

  defp fallback_leg_seconds(from_lat, from_lng, to_lat, to_lng) do
    distance_m = Geo.haversine_distance_m(from_lat, from_lng, to_lat, to_lng)
    speed_mps = policy().fallback_speed_kph * 1000.0 / 3600.0
    seconds = trunc(Float.ceil(distance_m / max(speed_mps, 1.0)))
    clamp_duration(seconds)
  end

  defp clamp_duration(value) when is_integer(value) do
    value
    |> max(policy().min_leg_seconds)
    |> min(policy().max_leg_seconds)
  end

  defp clamp_duration(value) when is_float(value), do: clamp_duration(trunc(Float.ceil(value)))
  defp clamp_duration(_value), do: policy().min_leg_seconds

  defp google_enabled?, do: policy().google_enabled

  defp policy do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      google_enabled: get_bool(config, :google_enabled, @defaults.google_enabled),
      fallback_speed_kph: get_number(config, :fallback_speed_kph, @defaults.fallback_speed_kph),
      min_leg_seconds: get_int(config, :min_leg_seconds, @defaults.min_leg_seconds),
      max_leg_seconds: get_int(config, :max_leg_seconds, @defaults.max_leg_seconds)
    }
  end

  defp get_bool(config, key, default) do
    case Keyword.get(config, key, default) do
      value when value in [true, false] -> value
      _ -> default
    end
  end

  defp get_number(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _ -> default
    end
  end

  defp get_int(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp routes_client,
    do: Application.get_env(:liddr, :google_routes_client, Liddr.Maps.RoutesClient)
end
