defmodule Liddr.Rides.DestinationChanges.Support do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideDestinationChange
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.RoutePricing
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @max_changes_per_ride 2

  def ensure_destination_change_allowed!(%Ride{status: status, product_type: product_type}) do
    cond do
      status != "in_progress" -> Repo.rollback(:ride_destination_change_not_allowed)
      product_type == "shared" -> Repo.rollback(:ride_destination_change_not_allowed_for_shared)
      true -> :ok
    end
  end

  def ensure_destination_change_quota!(ride_id) do
    count =
      Repo.aggregate(
        from(dc in RideDestinationChange, where: dc.ride_id == ^ride_id),
        :count,
        :id
      )

    if count >= @max_changes_per_ride,
      do: Repo.rollback(:destination_change_limit_reached),
      else: :ok
  end

  def ensure_no_open_change!(ride_id) do
    open_exists? =
      Repo.exists?(
        from dc in RideDestinationChange,
          where: dc.ride_id == ^ride_id and dc.status == "requested"
      )

    if open_exists?, do: Repo.rollback(:destination_change_already_pending), else: :ok
  end

  def fetch_open_change_for_update!(ride_id, change_id, driver_user_id) do
    parsed_id =
      Shared.parse_positive_integer(change_id) || Repo.rollback(:destination_change_not_found)

    Repo.one(
      from dc in RideDestinationChange,
        where:
          dc.id == ^parsed_id and dc.ride_id == ^ride_id and dc.driver_id == ^driver_user_id and
            dc.status == "requested",
        lock: "FOR UPDATE"
    ) || Repo.rollback(:destination_change_not_found)
  end

  def resolve_reason_code!(attrs, allowed_codes) do
    reason =
      attrs
      |> PaymentUtils.get_value(:reason_code)
      |> PaymentUtils.normalize_text()

    if reason in allowed_codes,
      do: reason,
      else: Repo.rollback(:invalid_destination_change_reason)
  end

  def resolve_optional_reason_code(attrs, allowed_codes) do
    reason =
      attrs
      |> PaymentUtils.get_value(:reason_code)
      |> PaymentUtils.normalize_text()

    cond do
      is_nil(reason) -> {:ok, "driver_declined"}
      reason in allowed_codes -> {:ok, reason}
      true -> {:error, :invalid_destination_change_reason}
    end
  end

  def resolve_notes(attrs) do
    attrs
    |> PaymentUtils.get_value(:notes)
    |> PaymentUtils.normalize_text()
  end

  def fetch_new_dropoff!(attrs) do
    with {:ok, lat} <-
           parse_coordinate(PaymentUtils.get_value(attrs, :new_dropoff_lat), -90.0, 90.0),
         {:ok, lng} <-
           parse_coordinate(PaymentUtils.get_value(attrs, :new_dropoff_lng), -180.0, 180.0) do
      %{lat: lat, lng: lng}
    else
      _ -> Repo.rollback(:invalid_destination_coordinates)
    end
  end

  def ensure_destination_changed!(ride, destination) do
    current_lat = ride.dropoff_lat |> to_float()
    current_lng = ride.dropoff_lng |> to_float()

    if abs(current_lat - destination.lat) < 0.00001 and
         abs(current_lng - destination.lng) < 0.00001 do
      Repo.rollback(:destination_change_same_as_current)
    else
      :ok
    end
  end

  def fetch_vehicle_category!(category_id) do
    Repo.get(VehicleCategory, category_id) || Repo.rollback(:vehicle_category_not_found)
  end

  def current_origin_point(%Ride{
        driver_id: driver_user_id,
        pickup_lat: pickup_lat,
        pickup_lng: pickup_lng
      }) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^driver_user_id,
          order_by: [desc: dl.captured_at],
          limit: 1
      )

    if location do
      %{lat: to_float(location.lat), lng: to_float(location.lng)}
    else
      %{lat: to_float(pickup_lat), lng: to_float(pickup_lng)}
    end
  end

  def current_planned_fare(%Ride{} = ride) do
    quote =
      case ride.quote_id do
        nil -> nil
        quote_id -> Repo.get(RideQuote, quote_id)
      end

    metadata_fare =
      ride.metadata
      |> Shared.normalize_metadata()
      |> Map.get("quoted_final_fare_kes")
      |> parse_decimal()

    metadata_fare || (quote && quote.final_fare_kes) || ride.final_fare_kes || D.new("0.00")
  end

  def estimate_route_pricing!(category, origin, destination, now) do
    case RoutePricing.estimate(category, origin, destination, now) do
      {:ok, payload} -> payload
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def destination_change_metadata(metadata, change) do
    metadata = Shared.normalize_metadata(metadata)
    existing = Map.get(metadata, "destination_changes", [])

    entry = %{
      "destination_change_id" => change.id,
      "accepted_at" => change.responded_at,
      "old_dropoff_lat" => RoutePricing.decimal_to_string(change.old_dropoff_lat),
      "old_dropoff_lng" => RoutePricing.decimal_to_string(change.old_dropoff_lng),
      "new_dropoff_lat" => RoutePricing.decimal_to_string(change.new_dropoff_lat),
      "new_dropoff_lng" => RoutePricing.decimal_to_string(change.new_dropoff_lng),
      "old_fare_kes" => RoutePricing.decimal_to_string(change.old_fare_kes),
      "new_fare_kes" => RoutePricing.decimal_to_string(change.new_fare_kes),
      "fare_delta_kes" => RoutePricing.decimal_to_string(change.fare_delta_kes)
    }

    metadata
    |> Map.put("quoted_final_fare_kes", RoutePricing.decimal_to_string(change.new_fare_kes))
    |> Map.put("destination_changes", existing ++ [entry])
  end

  def destination_change_event_payload(change) do
    %{
      "destination_change_id" => change.id,
      "status" => change.status,
      "reason_code" => change.reason_code,
      "old_fare_kes" => RoutePricing.decimal_to_string(change.old_fare_kes),
      "new_fare_kes" => RoutePricing.decimal_to_string(change.new_fare_kes),
      "fare_delta_kes" => RoutePricing.decimal_to_string(change.fare_delta_kes),
      "new_dropoff_lat" => RoutePricing.decimal_to_string(change.new_dropoff_lat),
      "new_dropoff_lng" => RoutePricing.decimal_to_string(change.new_dropoff_lng)
    }
  end

  def pricing_payload(estimate) do
    %{
      "route" => %{
        "distance_m" => estimate.route.distance_m,
        "duration_s" => estimate.route.duration_s,
        "static_duration_s" => estimate.route.static_duration_s,
        "polyline" => estimate.route.polyline
      },
      "routing" => %{
        "travel_mode" => estimate.routing.travel_mode,
        "routing_preference" => estimate.routing.routing_preference,
        "departure_time" => estimate.routing.departure_time
      },
      "pricing" => %{
        "base_fare_kes" => RoutePricing.decimal_to_string(estimate.pricing.base_fare_kes),
        "discount_percent" => RoutePricing.decimal_to_string(estimate.pricing.discount_percent),
        "discount_amount_kes" =>
          RoutePricing.decimal_to_string(estimate.pricing.discount_amount_kes),
        "final_fare_kes" => RoutePricing.decimal_to_string(estimate.pricing.final_fare_kes)
      }
    }
  end

  def to_decimal(value), do: D.from_float(value) |> D.round(7)

  defp parse_coordinate(value, min, max) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= min and parsed <= max -> {:ok, parsed}
      _ -> {:error, :invalid_coordinate}
    end
  end

  defp parse_coordinate(value, min, max) when is_integer(value),
    do: parse_coordinate(value * 1.0, min, max)

  defp parse_coordinate(value, min, max) when is_float(value) and value >= min and value <= max,
    do: {:ok, value}

  defp parse_coordinate(_value, _min, _max), do: {:error, :invalid_coordinate}

  defp to_float(%D{} = value), do: D.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_value), do: 0.0

  defp parse_decimal(%D{} = value), do: value

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(_value), do: nil
end
