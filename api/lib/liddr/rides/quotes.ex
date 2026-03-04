defmodule Liddr.Rides.Quotes do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.RoutePricing
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @default_quote_ttl_seconds 180
  @max_quote_ttl_seconds 900

  def create_quote(rider_user_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, _rider} <- fetch_rider(rider_user_id),
         {:ok, category} <- fetch_vehicle_category(attrs),
         {:ok, origin} <- fetch_point(attrs, :pickup),
         {:ok, destination} <- fetch_point(attrs, :dropoff),
         {:ok, estimate} <- RoutePricing.estimate(category, origin, destination, now) do
      expires_at = DateTime.add(now, quote_ttl_seconds(attrs), :second)

      params = %{
        "rider_id" => rider_user_id,
        "vehicle_category_id" => category.id,
        "pickup_lat" => to_decimal(origin.lat),
        "pickup_lng" => to_decimal(origin.lng),
        "dropoff_lat" => to_decimal(destination.lat),
        "dropoff_lng" => to_decimal(destination.lng),
        "distance_m" => estimate.route.distance_m,
        "duration_s" => estimate.route.duration_s,
        "static_duration_s" => estimate.route.static_duration_s,
        "base_amount_kes" => estimate.pricing.base_amount_kes,
        "distance_amount_kes" => estimate.pricing.distance_amount_kes,
        "time_amount_kes" => estimate.pricing.time_amount_kes,
        "min_fare_kes" => estimate.pricing.min_fare_kes,
        "surge_multiplier" => estimate.pricing.surge_multiplier,
        "subtotal_kes" => estimate.pricing.subtotal_kes,
        "base_fare_kes" => estimate.pricing.base_fare_kes,
        "discount_percent" => estimate.pricing.discount_percent,
        "discount_amount_kes" => estimate.pricing.discount_amount_kes,
        "final_fare_kes" => estimate.pricing.final_fare_kes,
        "currency" => "KES",
        "provider" => "google_routes",
        "provider_payload" => %{
          "polyline" => estimate.route.polyline,
          "travel_mode" => estimate.routing.travel_mode,
          "routing_preference" => estimate.routing.routing_preference,
          "departure_time" => estimate.routing.departure_time,
          "time_multiplier" =>
            RoutePricing.decimal_to_string(estimate.multipliers.time_multiplier),
          "demand_multiplier" =>
            RoutePricing.decimal_to_string(estimate.multipliers.demand_multiplier),
          "market_multiplier" =>
            RoutePricing.decimal_to_string(estimate.multipliers.market_multiplier),
          "demand_ratio" => RoutePricing.decimal_to_string(estimate.multipliers.demand_ratio),
          "available_driver_count" => estimate.multipliers.available_driver_count,
          "active_request_count" => estimate.multipliers.active_request_count
        },
        "expires_at" => expires_at
      }

      %RideQuote{}
      |> RideQuote.create_changeset(params)
      |> Repo.insert()
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_rider(rider_user_id) do
    case Repo.get(User, rider_user_id) do
      nil -> {:error, :rider_not_found}
      rider -> {:ok, rider}
    end
  end

  defp fetch_vehicle_category(attrs) do
    with {:ok, category_id} <-
           parse_positive_integer(PaymentUtils.get_value(attrs, :vehicle_category_id)),
         %VehicleCategory{} = category <-
           Repo.one(
             from(vc in VehicleCategory, where: vc.id == ^category_id and vc.is_active == true)
           ) do
      {:ok, category}
    else
      {:error, :invalid_integer} -> {:error, :invalid_vehicle_category_id}
      nil -> {:error, :vehicle_category_not_found}
    end
  end

  defp fetch_point(attrs, point_key) do
    lat_key = :"#{point_key}_lat"
    lng_key = :"#{point_key}_lng"

    with {:ok, lat} <- parse_coordinate(PaymentUtils.get_value(attrs, lat_key), -90.0, 90.0),
         {:ok, lng} <- parse_coordinate(PaymentUtils.get_value(attrs, lng_key), -180.0, 180.0) do
      {:ok, %{lat: lat, lng: lng}}
    else
      _ -> {:error, {:invalid_coordinates, point_key}}
    end
  end

  defp quote_ttl_seconds(attrs) do
    attrs
    |> PaymentUtils.get_value(:quote_ttl_seconds)
    |> parse_positive_integer()
    |> clamp(@default_quote_ttl_seconds, @max_quote_ttl_seconds)
  end

  defp parse_coordinate(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> validate_coordinate(parsed, min, max)
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(value, min, max) when is_float(value),
    do: validate_coordinate(value, min, max)

  defp parse_coordinate(value, min, max) when is_integer(value),
    do: validate_coordinate(value * 1.0, min, max)

  defp parse_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp validate_coordinate(value, min, max) when value >= min and value <= max, do: {:ok, value}
  defp validate_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_integer}

  defp clamp({:ok, value}, _default, max) when value > max, do: max
  defp clamp({:ok, value}, _default, _max), do: value
  defp clamp(_value, default, _max), do: default

  defp to_decimal(value), do: D.from_float(value) |> D.round(7)
end
