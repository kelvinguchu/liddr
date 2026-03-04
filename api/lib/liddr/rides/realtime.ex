defmodule Liddr.Rides.Realtime do
  alias Liddr.Ratings.Snapshot
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias LiddrWeb.Endpoint
  alias LiddrWeb.RideSerializer

  def broadcast_offer_created(%Ride{} = ride, %RideOffer{} = offer) do
    emitted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    snapshot_index = Snapshot.build_index([ride.rider_id, ride.driver_id, offer.driver_id])

    payload = %{
      ride: RideSerializer.ride_payload(ride, snapshot_index),
      offer: RideSerializer.offer_payload(offer, snapshot_index, ride.rider_id),
      reason_code: "dispatch_offer_created",
      emitted_at: emitted_at
    }

    Endpoint.broadcast("driver:#{offer.driver_id}", "ride_offer_created", payload)
    Endpoint.broadcast("ride:#{ride.id}", "ride_offer_created", payload)
  end

  def broadcast_offer_expired(%Ride{} = ride, %RideOffer{} = offer) do
    emitted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    snapshot_index = Snapshot.build_index([ride.rider_id, ride.driver_id, offer.driver_id])

    payload = %{
      ride: RideSerializer.ride_payload(ride, snapshot_index),
      offer: RideSerializer.offer_payload(offer, snapshot_index, ride.rider_id),
      reason_code: "offer_ttl_expired",
      emitted_at: emitted_at
    }

    Endpoint.broadcast("driver:#{offer.driver_id}", "ride_offer_expired", payload)
    Endpoint.broadcast("ride:#{ride.id}", "ride_offer_expired", payload)
  end

  def broadcast_offer_withdrawn(ride_id, %RideOffer{} = offer, reason_code) do
    emitted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payload = %{
      ride_id: ride_id,
      reason_code: to_string(reason_code),
      offer: RideSerializer.offer_payload(offer),
      emitted_at: emitted_at
    }

    Endpoint.broadcast("driver:#{offer.driver_id}", "ride_offer_withdrawn", payload)
    Endpoint.broadcast("ride:#{ride_id}", "ride_offer_withdrawn", payload)
  end

  def broadcast_ride_assigned(%Ride{} = ride, %RideOffer{} = offer) do
    snapshot_index = Snapshot.build_index([ride.rider_id, ride.driver_id, offer.driver_id])
    emitted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payload = %{
      ride: RideSerializer.ride_payload(ride, snapshot_index),
      offer: RideSerializer.offer_payload(offer, snapshot_index, ride.rider_id),
      emitted_at: emitted_at
    }

    recipient_user_ids =
      Notifications.queue_realtime_event!(ride, "ride_assigned", payload, emitted_at)

    Endpoint.broadcast("driver:#{offer.driver_id}", "ride_assigned", payload)
    Endpoint.broadcast("ride:#{ride.id}", "ride_assigned", payload)
    _ = Notifications.mark_socket_sent(ride.id, "ride_assigned", recipient_user_ids, emitted_at)
  end

  def broadcast_driver_arriving(%Ride{} = ride) do
    payload = %{ride: RideSerializer.ride_payload(ride)}
    broadcast_ride_and_driver(ride, "driver_arriving", payload)
  end

  def broadcast_driver_arrived(%Ride{} = ride) do
    payload = %{ride: RideSerializer.ride_payload(ride)}
    broadcast_ride_and_driver(ride, "driver_arrived", payload)
  end

  def broadcast_trip_started(%Ride{} = ride) do
    payload = %{ride: RideSerializer.ride_payload(ride)}
    broadcast_ride_and_driver(ride, "trip_started", payload)
  end

  def broadcast_trip_cancelled(%Ride{} = ride, reason) do
    emitted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payload = %{
      ride: RideSerializer.ride_payload(ride),
      reason_code: to_string(reason),
      emitted_at: emitted_at
    }

    broadcast_ride_and_driver(ride, "trip_cancelled", payload)
  end

  def broadcast_ride_completed(%Ride{} = ride) do
    payload = %{ride: RideSerializer.ride_payload(ride)}
    broadcast_ride_and_driver(ride, "ride_completed", payload)
  end

  def broadcast_ride_reassigned(%Ride{} = ride, health_payload) do
    payload = %{
      ride: RideSerializer.ride_payload(ride),
      pickup_health: health_payload,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    broadcast_ride_and_driver(ride, "ride_reassigned", payload)
  end

  def broadcast_rating_pending(%Ride{} = ride, due_at) do
    payload = %{
      ride_id: ride.id,
      rider_id: ride.rider_id,
      driver_id: ride.driver_id,
      due_at: due_at,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    broadcast_ride_and_driver(ride, "rating_pending", payload)
  end

  def broadcast_rating_submitted(ride_id, driver_id, rating) do
    payload = %{
      ride_id: ride_id,
      rating_id: rating.id,
      rated_by_user_id: rating.rated_by_user_id,
      rated_user_id: rating.rated_user_id,
      score: rating.score,
      include_in_score: rating.include_in_score,
      exclusion_reason_code: rating.exclusion_reason_code,
      submitted_at: rating.submitted_at,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    Endpoint.broadcast("ride:#{ride_id}", "rating_submitted", payload)
    maybe_broadcast_driver(driver_id, "rating_submitted", payload)
  end

  def broadcast_rating_skipped(ride_id, driver_id, rated_by_user_id) do
    payload = %{
      ride_id: ride_id,
      rated_by_user_id: rated_by_user_id,
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    Endpoint.broadcast("ride:#{ride_id}", "rating_skipped", payload)
    maybe_broadcast_driver(driver_id, "rating_skipped", payload)
  end

  def broadcast_driver_unlocked(driver_id, ride_id) when is_integer(driver_id) do
    Endpoint.broadcast("driver:#{driver_id}", "driver_unlocked", %{
      driver_id: driver_id,
      ride_id: ride_id
    })
  end

  def broadcast_destination_change_requested(%Ride{} = ride, change) do
    payload = %{
      ride: RideSerializer.ride_payload(ride),
      destination_change: RideSerializer.destination_change_payload(change)
    }

    broadcast_ride_and_driver(ride, "destination_change_requested", payload)
  end

  def broadcast_destination_change_accepted(%Ride{} = ride, change) do
    payload = %{
      ride: RideSerializer.ride_payload(ride),
      destination_change: RideSerializer.destination_change_payload(change)
    }

    broadcast_ride_and_driver(ride, "destination_change_accepted", payload)
  end

  def broadcast_destination_change_rejected(%Ride{} = ride, change) do
    payload = %{
      ride: RideSerializer.ride_payload(ride),
      destination_change: RideSerializer.destination_change_payload(change)
    }

    broadcast_ride_and_driver(ride, "destination_change_rejected", payload)
  end

  defp broadcast_ride_and_driver(ride, event, payload) do
    emitted_at = payload[:emitted_at] || DateTime.utc_now() |> DateTime.truncate(:microsecond)
    payload = Map.put_new(payload, :emitted_at, emitted_at)
    recipient_user_ids = Notifications.queue_realtime_event!(ride, event, payload, emitted_at)

    if ride.driver_id, do: Endpoint.broadcast("driver:#{ride.driver_id}", event, payload)
    Endpoint.broadcast("ride:#{ride.id}", event, payload)
    _ = Notifications.mark_socket_sent(ride.id, event, recipient_user_ids, emitted_at)
  end

  defp maybe_broadcast_driver(driver_id, event, payload) when is_integer(driver_id) do
    Endpoint.broadcast("driver:#{driver_id}", event, payload)
  end

  defp maybe_broadcast_driver(_driver_id, _event, _payload), do: :ok
end
