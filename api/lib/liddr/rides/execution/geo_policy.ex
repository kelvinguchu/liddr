defmodule Liddr.Rides.Execution.GeoPolicy do
  @default_config [
    pickup_arrival_radius_m: 120,
    dropoff_completion_radius_m: 180,
    location_freshness_seconds: 120,
    no_show_wait_seconds: 300,
    require_geofence_on_arrive: true,
    require_geofence_on_complete: true
  ]

  def pickup_arrival_radius_m, do: get_int(:pickup_arrival_radius_m, 120, 20, 2_000)

  def dropoff_completion_radius_m,
    do: get_int(:dropoff_completion_radius_m, 180, 20, 2_000)

  def location_freshness_seconds,
    do: get_int(:location_freshness_seconds, 120, 10, 3_600)

  def no_show_wait_seconds, do: get_int(:no_show_wait_seconds, 300, 30, 3_600)

  def require_geofence_on_arrive?, do: get_bool(:require_geofence_on_arrive, true)
  def require_geofence_on_complete?, do: get_bool(:require_geofence_on_complete, true)

  defp get_config, do: Application.get_env(:liddr, __MODULE__, @default_config)

  defp get_int(key, default, min, max) do
    value =
      get_config()
      |> Keyword.get(key, default)
      |> case do
        int when is_integer(int) -> int
        float when is_float(float) -> round(float)
        binary when is_binary(binary) -> parse_int(binary, default)
        _ -> default
      end

    if value < min or value > max, do: default, else: value
  end

  defp get_bool(key, default) do
    get_config()
    |> Keyword.get(key, default)
    |> case do
      value when value in [true, "true", "1", "yes", "on"] -> true
      value when value in [false, "false", "0", "no", "off"] -> false
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end
end
