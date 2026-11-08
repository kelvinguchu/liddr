defmodule Liddr.Maps.RoutesClient.Config do
  @default_base_url "https://routes.googleapis.com"
  @default_timeout_ms 7_000

  def fetch do
    with {:ok, api_key} <- fetch_env("GOOGLE_MAPS_API_KEY_SERVER") do
      {:ok,
       %{
         api_key: api_key,
         base_url:
           System.get_env("GOOGLE_ROUTES_BASE_URL")
           |> normalize_text(@default_base_url)
           |> String.trim_trailing("/"),
         timeout_ms:
           System.get_env("GOOGLE_ROUTES_TIMEOUT_MS")
           |> parse_positive_integer(@default_timeout_ms),
         default_routing_preference:
           System.get_env("GOOGLE_ROUTES_ROUTING_PREFERENCE")
           |> normalize_text("TRAFFIC_AWARE"),
         default_travel_mode:
           System.get_env("GOOGLE_ROUTES_TRAVEL_MODE")
           |> normalize_text("DRIVE")
       }}
    end
  end

  defp fetch_env(key) do
    case System.get_env(key) do
      nil ->
        {:error, {:missing_google_maps_env, key}}

      value ->
        normalized = String.trim(value)

        if normalized == "",
          do: {:error, {:missing_google_maps_env, key}},
          else: {:ok, normalized}
    end
  end

  defp normalize_text(nil, default), do: default

  defp normalize_text(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      normalized -> normalized
    end
  end

  defp normalize_text(value, default), do: value |> to_string() |> normalize_text(default)

  defp parse_positive_integer(nil, default), do: default

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_positive_integer(_value, default), do: default
end
