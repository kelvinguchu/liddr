defmodule Liddr.Rides.DestinationChanges.Policy do
  @moduledoc false

  @default_policy [
    max_elapsed_seconds: 3_600,
    cooldown_seconds: 45,
    request_ttl_seconds: 180,
    origin_location_freshness_seconds: 120
  ]

  def max_elapsed_seconds, do: get_int(:max_elapsed_seconds, 3_600, 60, 86_400)
  def cooldown_seconds, do: get_int(:cooldown_seconds, 45, 0, 3_600)
  def request_ttl_seconds, do: get_int(:request_ttl_seconds, 180, 30, 3_600)

  def origin_location_freshness_seconds,
    do: get_int(:origin_location_freshness_seconds, 120, 10, 3_600)

  defp get_config, do: Application.get_env(:liddr, __MODULE__, @default_policy)

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

  defp parse_int(value, default) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end
end
