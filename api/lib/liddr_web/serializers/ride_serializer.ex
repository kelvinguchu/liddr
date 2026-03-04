defmodule LiddrWeb.RideSerializer do
  alias Liddr.Rides.CancellationOutcome
  alias Liddr.Ratings.Snapshot

  def quote_payload(quote) do
    product_type = provider_value(quote, "product_type") || "solo"

    %{
      id: quote.id,
      rider_id: quote.rider_id,
      vehicle_category_id: quote.vehicle_category_id,
      product_type: product_type,
      pickup: %{lat: quote.pickup_lat, lng: quote.pickup_lng},
      dropoff: %{lat: quote.dropoff_lat, lng: quote.dropoff_lng},
      route: %{
        distance_m: quote.distance_m,
        duration_s: quote.duration_s,
        static_duration_s: quote.static_duration_s,
        provider: quote.provider,
        travel_mode: provider_value(quote, "travel_mode"),
        routing_preference: provider_value(quote, "routing_preference"),
        departure_time: provider_value(quote, "departure_time")
      },
      pricing: %{
        base_amount_kes: quote.base_amount_kes,
        distance_amount_kes: quote.distance_amount_kes,
        time_amount_kes: quote.time_amount_kes,
        min_fare_kes: quote.min_fare_kes,
        surge_multiplier: quote.surge_multiplier,
        time_multiplier: provider_value(quote, "time_multiplier"),
        demand_multiplier: provider_value(quote, "demand_multiplier"),
        market_multiplier: provider_value(quote, "market_multiplier"),
        demand_ratio: provider_value(quote, "demand_ratio"),
        available_driver_count: provider_value(quote, "available_driver_count"),
        active_request_count: provider_value(quote, "active_request_count"),
        shared_pricing: provider_value(quote, "shared_pricing"),
        subtotal_kes: quote.subtotal_kes,
        base_fare_kes: quote.base_fare_kes,
        discount_percent: quote.discount_percent,
        discount_amount_kes: quote.discount_amount_kes,
        final_fare_kes: quote.final_fare_kes,
        currency: quote.currency
      },
      expires_at: quote.expires_at,
      inserted_at: quote.inserted_at
    }
  end

  def request_payload(payload) do
    snapshot_index =
      build_snapshot_index([
        payload.ride.rider_id,
        payload.ride.driver_id | Enum.map(payload.offers, & &1.driver_id)
      ])

    base = %{
      ride: ride_payload(payload.ride, snapshot_index),
      offers: Enum.map(payload.offers, &offer_payload(&1, snapshot_index, payload.ride.rider_id)),
      offers_count: length(payload.offers)
    }

    case Map.get(payload, :shared_join) do
      %{} = shared_join -> Map.put(base, :shared_join, shared_join)
      _ -> base
    end
  end

  def accept_payload(payload) do
    snapshot_index =
      build_snapshot_index([
        payload.ride.rider_id,
        payload.ride.driver_id,
        payload.offer.driver_id
      ])

    %{
      ride: ride_payload(payload.ride, snapshot_index),
      offer: offer_payload(payload.offer, snapshot_index, payload.ride.rider_id)
    }
  end

  def driver_offer_payload(%{offer: offer, ride: ride}) do
    snapshot_index = build_snapshot_index([offer.driver_id, ride.rider_id, ride.driver_id])

    %{
      offer: offer_payload(offer, snapshot_index, ride.rider_id),
      ride: ride_payload(ride, snapshot_index)
    }
  end

  def history_payload(rides) do
    snapshot_index =
      rides
      |> Enum.flat_map(fn ride -> [ride.rider_id, ride.driver_id] end)
      |> build_snapshot_index()

    %{rides: Enum.map(rides, &ride_payload(&1, snapshot_index))}
  end

  def events_payload(events, next_since) do
    %{
      events: Enum.map(events, &event_payload/1),
      next_since: next_since
    }
  end

  def ride_payload(ride),
    do: ride_payload(ride, build_snapshot_index([ride.rider_id, ride.driver_id]))

  def ride_payload(ride, snapshot_index) do
    %{
      id: ride.id,
      rider_id: ride.rider_id,
      driver_id: ride.driver_id,
      quote_id: ride.quote_id,
      vehicle_category_id: ride.vehicle_category_id,
      status: ride.status,
      product_type: ride.product_type,
      pickup_lat: ride.pickup_lat,
      pickup_lng: ride.pickup_lng,
      dropoff_lat: ride.dropoff_lat,
      dropoff_lng: ride.dropoff_lng,
      requested_at: ride.requested_at,
      accepted_at: ride.accepted_at,
      driver_arriving_at: ride.driver_arriving_at,
      arrived_at: ride.arrived_at,
      started_at: ride.started_at,
      arrival_distance_m: ride.arrival_distance_m,
      completion_distance_m: ride.completion_distance_m,
      cancelled_at: ride.cancelled_at,
      cancellation_reason_code: ride.cancellation_reason_code,
      cancellation_outcome: CancellationOutcome.from_ride(ride),
      cancelled_by_user_id: ride.cancelled_by_user_id,
      no_show_marked_at: ride.no_show_marked_at,
      completed_at: ride.completed_at,
      payment_mode: ride.payment_mode,
      final_fare_kes: ride.final_fare_kes,
      final_pricing_payload: ride.final_pricing_payload,
      notes: ride.notes,
      rider_rating_snapshot: Snapshot.snapshot_for_role(ride.rider_id, :rider, snapshot_index),
      driver_rating_snapshot: Snapshot.snapshot_for_role(ride.driver_id, :driver, snapshot_index),
      inserted_at: ride.inserted_at
    }
  end

  def offer_payload(offer), do: offer_payload(offer, build_snapshot_index([offer.driver_id]), nil)

  def offer_payload(offer, snapshot_index, rider_user_id) do
    window_seconds = response_window_seconds(offer)

    %{
      id: offer.id,
      ride_id: offer.ride_id,
      driver_id: offer.driver_id,
      status: offer.status,
      response_state: response_state(offer),
      offered_at: offer.offered_at,
      responded_at: offer.responded_at,
      expires_at: offer.expires_at,
      response_window_seconds: window_seconds,
      response_window_remaining_seconds: response_window_remaining_seconds(offer),
      driver_rating_snapshot:
        Snapshot.snapshot_for_role(offer.driver_id, :driver, snapshot_index),
      rider_rating_snapshot: Snapshot.snapshot_for_role(rider_user_id, :rider, snapshot_index),
      inserted_at: offer.inserted_at
    }
  end

  def event_payload(event) do
    %{
      id: event.id,
      ride_id: event.ride_id,
      actor_user_id: event.actor_user_id,
      event_type: event.event_type,
      payload: event.payload,
      occurred_at: event.occurred_at,
      inserted_at: event.inserted_at
    }
  end

  def destination_change_payload(change) do
    %{
      id: change.id,
      ride_id: change.ride_id,
      requested_by_user_id: change.requested_by_user_id,
      driver_id: change.driver_id,
      old_dropoff_lat: change.old_dropoff_lat,
      old_dropoff_lng: change.old_dropoff_lng,
      new_dropoff_lat: change.new_dropoff_lat,
      new_dropoff_lng: change.new_dropoff_lng,
      old_fare_kes: change.old_fare_kes,
      new_fare_kes: change.new_fare_kes,
      fare_delta_kes: change.fare_delta_kes,
      status: change.status,
      reason_code: change.reason_code,
      notes: change.notes,
      requested_at: change.requested_at,
      responded_at: change.responded_at,
      pricing_payload: change.pricing_payload,
      inserted_at: change.inserted_at
    }
  end

  defp provider_value(quote, key) do
    case quote.provider_payload do
      %{} = payload -> Map.get(payload, key)
      _ -> nil
    end
  end

  defp build_snapshot_index(user_ids), do: Snapshot.build_index(user_ids)

  defp response_window_seconds(%{
         offered_at: %DateTime{} = offered_at,
         expires_at: %DateTime{} = expires_at
       }),
       do: max(DateTime.diff(expires_at, offered_at, :second), 0)

  defp response_window_seconds(_offer), do: nil

  defp response_window_remaining_seconds(%{
         status: "offered",
         expires_at: %DateTime{} = expires_at
       }) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    max(DateTime.diff(expires_at, now, :second), 0)
  end

  defp response_window_remaining_seconds(_offer), do: 0

  defp response_state(%{status: "offered", expires_at: %DateTime{} = expires_at}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    if DateTime.compare(expires_at, now) == :gt, do: "pending_response", else: "missed"
  end

  defp response_state(%{status: "expired"}), do: "missed"
  defp response_state(%{status: "accepted"}), do: "accepted"
  defp response_state(%{status: "rejected"}), do: "rejected"
  defp response_state(%{status: "withdrawn"}), do: "withdrawn"
  defp response_state(_offer), do: "unknown"
end
