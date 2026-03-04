defmodule Liddr.Rides.RoutePricing do
  alias Decimal, as: D
  alias Liddr.Rides.CategoryRouting
  alias Liddr.Rides.MarketMultiplier
  alias Liddr.Rides.Pricing
  alias Liddr.Rides.VehicleCategory

  def estimate(%VehicleCategory{} = category, origin, destination, now) do
    routing = CategoryRouting.for_category(category.slug, now)

    with {:ok, route} <- compute_route(origin, destination, routing),
         {:ok, multipliers} <- market_multiplier_module().build(category, origin, now) do
      pricing =
        Pricing.build_breakdown(category, %{
          distance_m: route.distance_m,
          duration_s: route.duration_s,
          surge_multiplier: multipliers.market_multiplier
        })

      {:ok, %{routing: routing, route: route, multipliers: multipliers, pricing: pricing}}
    end
  end

  def compute_route(origin, destination, routing) do
    input = %{
      origin: origin,
      destination: destination,
      travel_mode: routing.travel_mode,
      routing_preference: routing.routing_preference,
      departure_time: routing.departure_time
    }

    case compute_route_with_retry(input) do
      {:ok, payload} ->
        {:ok,
         %{
           distance_m: payload.distance_m,
           duration_s: payload.duration_s,
           static_duration_s: payload.static_duration_s,
           polyline: payload.polyline
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compute_route_with_retry(input) do
    case routes_client().compute_route(input) do
      {:error, reason} = error ->
        if timestamp_future_error?(reason) do
          fallback_input = Map.put(input, :departure_time, nil)

          case routes_client().compute_route(fallback_input) do
            {:ok, payload} -> {:ok, payload}
            _ -> error
          end
        else
          error
        end

      result ->
        result
    end
  end

  defp timestamp_future_error?({:google_maps_http_error, :compute_routes, 400, upstream_body}) do
    message =
      cond do
        is_map(upstream_body) -> get_in(upstream_body, ["error", "message"]) || ""
        is_binary(upstream_body) -> upstream_body
        true -> inspect(upstream_body)
      end

    String.contains?(String.downcase(message), "timestamp must be set to a future time")
  end

  defp timestamp_future_error?(_), do: false

  defp routes_client,
    do: Application.get_env(:liddr, :google_routes_client, Liddr.Maps.RoutesClient)

  defp market_multiplier_module,
    do: Application.get_env(:liddr, :ride_market_multiplier, MarketMultiplier)

  def decimal_to_string(%D{} = value), do: D.to_string(D.round(value, 2))
  def decimal_to_string(value) when is_integer(value), do: Integer.to_string(value)

  def decimal_to_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  def decimal_to_string(value), do: to_string(value)
end
