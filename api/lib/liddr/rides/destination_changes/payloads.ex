defmodule Liddr.Rides.DestinationChanges.Payloads do
  @moduledoc false

  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.RoutePricing

  def metadata(metadata, change) do
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

  def event_payload(change) do
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
end
