defmodule Liddr.Maps.RoutesClient do
  @behaviour Liddr.Maps.RoutesClientBehaviour

  alias Liddr.Maps.RoutesClient.Config
  alias Liddr.Maps.RoutesClient.Error

  @path "/directions/v2:computeRoutes"
  @field_mask "routes.distanceMeters,routes.duration,routes.staticDuration,routes.polyline.encodedPolyline"

  @impl true
  def compute_route(input) when is_map(input) do
    with {:ok, config} <- Config.fetch(),
         {:ok, origin} <- normalize_point(input, :origin),
         {:ok, destination} <- normalize_point(input, :destination) do
      payload =
        %{
          "origin" => lat_lng_point(origin),
          "destination" => lat_lng_point(destination),
          "travelMode" => fetch_string(input, :travel_mode, config.default_travel_mode),
          "routingPreference" =>
            fetch_string(input, :routing_preference, config.default_routing_preference),
          "computeAlternativeRoutes" => false,
          "units" => "METRIC",
          "languageCode" => "en-US"
        }
        |> maybe_put_departure_time(fetch_departure_time(input))

      case Req.post(config.base_url <> @path,
             headers: [
               {"x-goog-api-key", config.api_key},
               {"x-goog-fieldmask", @field_mask},
               {"content-type", "application/json"}
             ],
             json: payload,
             receive_timeout: config.timeout_ms
           ) do
        {:ok, %{status: status, body: %{"routes" => [route | _]} = body}}
        when status in 200..299 ->
          parse_route(route, body, status)

        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:error, Error.invalid_response(:compute_routes, status, body)}

        {:ok, %{status: status, body: body}} ->
          {:error, Error.http(:compute_routes, status, body)}

        {:error, reason} ->
          {:error, Error.transport(:compute_routes, reason)}
      end
    end
  end

  def compute_route(_input), do: {:error, :invalid_route_input}

  defp parse_route(route, raw, status) do
    with {:ok, distance_m} <- parse_positive_integer(route["distanceMeters"]),
         {:ok, duration_s} <- parse_duration_seconds(route["duration"]),
         {:ok, static_duration_s} <- parse_optional_duration_seconds(route["staticDuration"]) do
      {:ok,
       %{
         distance_m: distance_m,
         duration_s: duration_s,
         static_duration_s: static_duration_s,
         polyline: get_in(route, ["polyline", "encodedPolyline"]),
         raw: raw
       }}
    else
      _ -> {:error, Error.invalid_response(:compute_routes, status, raw)}
    end
  end

  defp normalize_point(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    case value do
      %{"lat" => lat, "lng" => lng} -> normalize_lat_lng(lat, lng)
      %{lat: lat, lng: lng} -> normalize_lat_lng(lat, lng)
      _ -> {:error, {:invalid_route_point, key}}
    end
  end

  defp normalize_lat_lng(lat, lng) do
    with {:ok, parsed_lat} <- parse_coordinate(lat, -90.0, 90.0),
         {:ok, parsed_lng} <- parse_coordinate(lng, -180.0, 180.0) do
      {:ok, %{lat: parsed_lat, lng: parsed_lng}}
    end
  end

  defp parse_coordinate(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> validate_coordinate(parsed, min, max)
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(value, min, max) when is_integer(value),
    do: validate_coordinate(value * 1.0, min, max)

  defp parse_coordinate(value, min, max) when is_float(value),
    do: validate_coordinate(value, min, max)

  defp parse_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp validate_coordinate(value, min, max) when value >= min and value <= max, do: {:ok, value}
  defp validate_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp lat_lng_point(%{lat: lat, lng: lng}) do
    %{"location" => %{"latLng" => %{"latitude" => lat, "longitude" => lng}}}
  end

  defp parse_positive_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_positive_integer(_value), do: {:error, :invalid_integer}

  defp parse_duration_seconds(nil), do: {:error, :missing_duration}

  defp parse_duration_seconds(value) when is_binary(value) do
    trimmed = String.trim(value)

    if String.ends_with?(trimmed, "s") do
      seconds = String.trim_trailing(trimmed, "s")

      case Float.parse(seconds) do
        {parsed, ""} when parsed >= 0 -> {:ok, trunc(Float.ceil(parsed))}
        _ -> {:error, :invalid_duration}
      end
    else
      {:error, :invalid_duration}
    end
  end

  defp parse_duration_seconds(_value), do: {:error, :invalid_duration}

  defp parse_optional_duration_seconds(nil), do: {:ok, nil}

  defp parse_optional_duration_seconds(value) do
    case parse_duration_seconds(value) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_duration}
    end
  end

  defp fetch_string(input, key, default) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    case value do
      nil ->
        default

      binary when is_binary(binary) ->
        case String.trim(binary) do
          "" -> default
          normalized -> normalized
        end

      _ ->
        default
    end
  end

  defp fetch_departure_time(input) do
    value = Map.get(input, :departure_time) || Map.get(input, "departure_time")

    cond do
      is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      match?(%DateTime{}, value) ->
        value
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      true ->
        nil
    end
  end

  defp maybe_put_departure_time(payload, nil), do: payload

  defp maybe_put_departure_time(payload, departure_time),
    do: Map.put(payload, "departureTime", departure_time)
end
