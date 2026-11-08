defmodule Liddr.Rides.RealtimeRatingsTest do
  use Liddr.DataCase, async: true

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.Endpoint

  test "rating lifecycle broadcasts to ride and driver topics" do
    category_id = VerificationFixtures.insert_vehicle_category!()
    rider = VerificationFixtures.create_user!()
    driver_user = VerificationFixtures.create_user!()

    driver =
      VerificationFixtures.create_driver!(user: driver_user, vehicle_category_id: category_id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        rider_id: rider.id,
        driver_id: driver.user_id,
        vehicle_category_id: category_id,
        status: "completed",
        pickup_lat: D.new("-1.2921"),
        pickup_lng: D.new("36.8219"),
        dropoff_lat: D.new("-1.3000"),
        dropoff_lng: D.new("36.8000"),
        requested_at: now,
        completed_at: now
      })
      |> Repo.insert!()

    ride_topic = "ride:#{ride.id}"
    driver_topic = "driver:#{ride.driver_id}"
    ride_id = ride.id
    due_at = DateTime.utc_now() |> DateTime.add(24 * 3600, :second) |> DateTime.truncate(:second)

    Endpoint.subscribe(ride_topic)
    Endpoint.subscribe(driver_topic)

    Realtime.broadcast_rating_pending(ride, due_at)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "rating_pending",
      payload: %{ride_id: ^ride_id, due_at: ^due_at}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "rating_pending",
      payload: %{ride_id: ^ride_id, due_at: ^due_at}
    }

    rating = %{
      id: 5001,
      rated_by_user_id: 101,
      rated_user_id: 202,
      score: 5,
      include_in_score: true,
      exclusion_reason_code: nil,
      submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Realtime.broadcast_rating_submitted(ride.id, ride.driver_id, rating)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "rating_submitted",
      payload: %{ride_id: ^ride_id, rating_id: 5001, score: 5}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "rating_submitted",
      payload: %{ride_id: ^ride_id, rating_id: 5001, score: 5}
    }

    Realtime.broadcast_rating_skipped(ride.id, ride.driver_id, 101)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "rating_skipped",
      payload: %{ride_id: ^ride_id, rated_by_user_id: 101}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "rating_skipped",
      payload: %{ride_id: ^ride_id, rated_by_user_id: 101}
    }
  end
end
