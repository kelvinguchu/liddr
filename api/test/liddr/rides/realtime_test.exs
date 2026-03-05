defmodule Liddr.Rides.RealtimeTest do
  use Liddr.DataCase, async: true

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  alias LiddrWeb.Endpoint

  setup do
    %{user_id: rider_id} = AuthFixtures.authenticate_with_role!("rider")
    %{user_id: driver_id} = AuthFixtures.authenticate_with_role!("driver")
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_eligible_driver_profile!(driver_id, category_id)

    ride = create_offering_ride!(rider_id, category_id)
    offer = create_offer!(ride.id, driver_id)

    _ =
      Repo.update_all(from(u in User, where: u.id == ^rider_id),
        set: [rating_score: D.new("4.93"), rating_count: 37]
      )

    _ =
      Repo.update_all(from(u in User, where: u.id == ^driver_id),
        set: [rating_score: D.new("4.52"), rating_count: 6]
      )

    Endpoint.subscribe("ride:#{ride.id}")
    Endpoint.subscribe("driver:#{driver_id}")

    %{ride: ride, offer: offer, driver_id: driver_id}
  end

  test "broadcast_offer_created publishes to ride and driver topics", %{ride: ride, offer: offer} do
    ride_id = ride.id
    offer_id = offer.id
    driver_id = offer.driver_id
    ride_topic = "ride:#{ride_id}"
    driver_topic = "driver:#{driver_id}"

    Realtime.broadcast_offer_created(ride, offer)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "ride_offer_created",
      payload: %{
        ride: %{id: ^ride_id, rider_rating_snapshot: %{rating_count: 37}},
        offer: %{
          id: ^offer_id,
          driver_id: ^driver_id,
          driver_rating_snapshot: %{rating_count: 6, is_new_driver: true},
          rider_rating_snapshot: %{rating_count: 37}
        },
        reason_code: "dispatch_offer_created",
        emitted_at: ride_emitted_at
      }
    }

    assert %DateTime{} = ride_emitted_at

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "ride_offer_created",
      payload: %{
        ride: %{id: ^ride_id, rider_rating_snapshot: %{rating_count: 37}},
        offer: %{id: ^offer_id, driver_rating_snapshot: %{rating_count: 6, is_new_driver: true}},
        reason_code: "dispatch_offer_created",
        emitted_at: driver_emitted_at
      }
    }

    assert %DateTime{} = driver_emitted_at
  end

  test "broadcast_offer_expired publishes to ride and driver topics", %{ride: ride, offer: offer} do
    ride_id = ride.id
    offer_id = offer.id
    driver_id = offer.driver_id
    ride_topic = "ride:#{ride_id}"
    driver_topic = "driver:#{driver_id}"
    expired_offer = %{offer | status: "expired"}
    Realtime.broadcast_offer_expired(ride, expired_offer)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "ride_offer_expired",
      payload: %{
        offer: %{id: ^offer_id, status: "expired"},
        reason_code: "offer_ttl_expired",
        emitted_at: ride_emitted_at
      }
    }

    assert %DateTime{} = ride_emitted_at

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "ride_offer_expired",
      payload: %{
        offer: %{id: ^offer_id, status: "expired"},
        reason_code: "offer_ttl_expired",
        emitted_at: driver_emitted_at
      }
    }

    assert %DateTime{} = driver_emitted_at
  end

  test "broadcast_offer_withdrawn publishes reason_code to ride and driver topics", %{
    ride: ride,
    offer: offer
  } do
    ride_id = ride.id
    offer_id = offer.id
    driver_id = offer.driver_id
    ride_topic = "ride:#{ride_id}"
    driver_topic = "driver:#{driver_id}"
    withdrawn_offer = %{offer | status: "withdrawn"}

    Realtime.broadcast_offer_withdrawn(ride_id, withdrawn_offer, :driver_rejected)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "ride_offer_withdrawn",
      payload: %{
        ride_id: ^ride_id,
        reason_code: "driver_rejected",
        offer: %{id: ^offer_id, status: "withdrawn"},
        emitted_at: ride_emitted_at
      }
    }

    assert %DateTime{} = ride_emitted_at

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "ride_offer_withdrawn",
      payload: %{
        ride_id: ^ride_id,
        reason_code: "driver_rejected",
        offer: %{id: ^offer_id, status: "withdrawn"},
        emitted_at: driver_emitted_at
      }
    }

    assert %DateTime{} = driver_emitted_at
  end

  test "broadcast ride assignment and unlock events", %{
    ride: ride,
    offer: offer,
    driver_id: driver_id
  } do
    ride_id = ride.id
    offer_id = offer.id
    ride_topic = "ride:#{ride_id}"
    driver_topic = "driver:#{driver_id}"
    accepted_offer = %{offer | status: "accepted"}
    assigned_ride = %{ride | driver_id: driver_id, status: "accepted"}

    Realtime.broadcast_ride_assigned(assigned_ride, accepted_offer)
    Realtime.broadcast_ride_completed(%{assigned_ride | id: ride_id, status: "completed"})
    Realtime.broadcast_driver_unlocked(driver_id, ride_id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "ride_assigned",
      payload: %{
        ride: %{
          id: ^ride_id,
          driver_id: ^driver_id,
          driver_rating_snapshot: %{rating_count: 6, is_new_driver: true},
          rider_rating_snapshot: %{rating_count: 37}
        },
        offer: %{id: ^offer_id, driver_rating_snapshot: %{rating_count: 6, is_new_driver: true}}
      }
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "ride_completed",
      payload: %{ride: %{id: ^ride_id, status: "completed"}}
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "driver_unlocked",
      payload: %{driver_id: ^driver_id, ride_id: ^ride_id}
    }
  end

  test "broadcast_shared_eta_updated publishes lightweight payload to ride and driver topics", %{
    ride: ride,
    driver_id: driver_id
  } do
    ride_id = ride.id
    ride_topic = "ride:#{ride_id}"
    driver_topic = "driver:#{driver_id}"

    next_stop = %{
      "id" => 9001,
      "member_id" => 77,
      "stop_type" => "pickup",
      "status" => "pending",
      "sequence" => 1,
      "lat" => Decimal.new("-1.2910000"),
      "lng" => Decimal.new("36.8220000"),
      "eta_at" => DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    Realtime.broadcast_shared_eta_updated(
      %{ride | driver_id: driver_id, status: "accepted"},
      next_stop
    )

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^ride_topic,
      event: "shared_eta_updated",
      payload: %{ride_id: ^ride_id, next_stop: %{"id" => 9001}, emitted_at: ride_emitted_at}
    }

    assert %DateTime{} = ride_emitted_at

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^driver_topic,
      event: "shared_eta_updated",
      payload: %{ride_id: ^ride_id, next_stop: %{"id" => 9001}, emitted_at: driver_emitted_at}
    }

    assert %DateTime{} = driver_emitted_at
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(User, user_id)

    VerificationFixtures.create_driver!(
      user: user,
      vehicle_category_id: category_id,
      account_status: "active",
      verification_status: "approved",
      subscription_status: "active",
      is_available: true
    )
  end

  defp create_offering_ride!(rider_id, category_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%Ride{
      rider_id: rider_id,
      vehicle_category_id: category_id,
      status: "offering",
      pickup_lat: Decimal.new("-1.2921000"),
      pickup_lng: Decimal.new("36.8219000"),
      dropoff_lat: Decimal.new("-1.3000000"),
      dropoff_lng: Decimal.new("36.8000000"),
      requested_at: now,
      metadata: %{}
    })
  end

  defp create_offer!(ride_id, driver_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%RideOffer{
      ride_id: ride_id,
      driver_id: driver_id,
      status: "offered",
      offered_at: now,
      expires_at: DateTime.add(now, 30, :second),
      metadata: %{}
    })
  end
end
