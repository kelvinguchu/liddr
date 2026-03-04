defmodule Liddr.Rides.PickupWatchdogTest do
  use Liddr.DataCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Rides.PickupWatchdog
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures

  test "auto-reassigns a stale pickup when policy threshold is reached" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    rider = VerificationFixtures.create_user!()
    first_driver_user = VerificationFixtures.create_user!()
    second_driver_user = VerificationFixtures.create_user!()

    first_driver =
      VerificationFixtures.create_driver!(
        user: first_driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: false
      )

    second_driver =
      VerificationFixtures.create_driver!(
        user: second_driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(first_driver.user_id,
        lat: Decimal.new("-1.3500000"),
        lng: Decimal.new("36.9000000"),
        captured_at: now
      )

    _ =
      VerificationFixtures.create_driver_location!(second_driver.user_id,
        lat: Decimal.new("-1.2922000"),
        lng: Decimal.new("36.8220000"),
        captured_at: now
      )

    ride =
      Repo.insert!(%Ride{
        rider_id: rider.id,
        driver_id: first_driver.user_id,
        vehicle_category_id: category_id,
        status: "accepted",
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: DateTime.add(now, -650, :second),
        accepted_at: DateTime.add(now, -600, :second),
        metadata: %{
          "driver_distance_to_pickup_m_at_accept" => 100,
          "promised_pickup_eta_s_at_accept" => 60
        }
      })

    _ =
      Repo.insert!(%RideOffer{
        ride_id: ride.id,
        driver_id: first_driver.user_id,
        status: "accepted",
        offered_at: DateTime.add(now, -610, :second),
        responded_at: DateTime.add(now, -600, :second),
        expires_at: DateTime.add(now, 300, :second),
        metadata: %{}
      })

    _ =
      Repo.update_all(
        from(d in Driver, where: d.user_id == ^first_driver.user_id),
        set: [current_ride_id: ride.id, dispatch_status: "heading_to_pickup", is_available: false]
      )

    result = PickupWatchdog.run(%{"now" => now, "limit" => 20})
    assert result.auto_reassigned == 1

    updated_ride = Repo.get!(Ride, ride.id)
    assert updated_ride.status == "offering"
    assert is_nil(updated_ride.driver_id)

    statuses =
      Repo.all(
        from o in RideOffer,
          where: o.ride_id == ^ride.id,
          select: {o.driver_id, o.status}
      )

    assert {first_driver.user_id, "withdrawn"} in statuses
    assert {second_driver.user_id, "offered"} in statuses
  end

  test "auto-cancels stale pickup after reassign threshold is exceeded" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!()
    rider = VerificationFixtures.create_user!()
    driver_user = VerificationFixtures.create_user!()

    driver =
      VerificationFixtures.create_driver!(
        user: driver_user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: false
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: Decimal.new("-1.3500000"),
        lng: Decimal.new("36.9000000"),
        captured_at: now
      )

    ride =
      Repo.insert!(%Ride{
        rider_id: rider.id,
        driver_id: driver.user_id,
        vehicle_category_id: category_id,
        status: "accepted",
        pickup_lat: Decimal.new("-1.2921000"),
        pickup_lng: Decimal.new("36.8219000"),
        dropoff_lat: Decimal.new("-1.3000000"),
        dropoff_lng: Decimal.new("36.8000000"),
        requested_at: DateTime.add(now, -1300, :second),
        accepted_at: DateTime.add(now, -1200, :second),
        metadata: %{
          "driver_distance_to_pickup_m_at_accept" => 100,
          "promised_pickup_eta_s_at_accept" => 60,
          "reassign_count" => 1
        }
      })

    _ =
      Repo.insert!(%RideOffer{
        ride_id: ride.id,
        driver_id: driver.user_id,
        status: "accepted",
        offered_at: DateTime.add(now, -1210, :second),
        responded_at: DateTime.add(now, -1200, :second),
        expires_at: DateTime.add(now, 300, :second),
        metadata: %{}
      })

    _ =
      Repo.update_all(
        from(d in Driver, where: d.user_id == ^driver.user_id),
        set: [current_ride_id: ride.id, dispatch_status: "heading_to_pickup", is_available: false]
      )

    result = PickupWatchdog.run(%{"now" => now, "limit" => 20})
    assert result.auto_cancelled == 1

    cancelled_ride = Repo.get!(Ride, ride.id)
    assert cancelled_ride.status == "cancelled"
    assert cancelled_ride.cancellation_reason_code == "driver_not_moving"

    refreshed_driver = Repo.get!(Driver, driver.user_id)
    assert is_nil(refreshed_driver.current_ride_id)
    assert refreshed_driver.dispatch_status == "idle"
    assert refreshed_driver.is_available == true
  end
end
