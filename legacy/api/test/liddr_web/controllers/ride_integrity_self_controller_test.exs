defmodule LiddrWeb.RideIntegritySelfControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "GET /api/rides/integrity/me returns rider tier and counters", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rider = Repo.get!(User, rider_user_id)

    _ =
      rider
      |> User.ride_booking_mode_changeset(%{
        "ride_booking_mode" => "prepay_only",
        "ride_booking_mode_until" => DateTime.add(now, 3600, :second)
      })
      |> Repo.update!()

    seed_chargeable_cancel!(rider_user_id, category_id, "rider", now)

    conn = get(rider_conn, "/api/rides/integrity/me")

    assert %{
             "data" => %{
               "user" => %{"id" => user_id},
               "counters" => %{"rider_chargeable_events_7d" => rider_count},
               "rider" => %{"tier" => %{"level" => "prepay_only", "active" => true}}
             }
           } = json_response(conn, 200)

    assert user_id == rider_user_id
    assert rider_count == 1
  end

  test "GET /api/rides/integrity/me returns driver missed-offer and chargeable counters", %{
    conn: conn
  } do
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => VerificationFixtures.create_user!().id,
        "driver_id" => driver_user_id,
        "vehicle_category_id" => category_id,
        "status" => "cancelled",
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "requested_at" => DateTime.add(now, -300, :second),
        "cancelled_at" => DateTime.add(now, -120, :second),
        "cancellation_reason_code" => "cannot_contact_rider",
        "cancelled_by_user_id" => driver_user_id,
        "metadata" => %{
          "integrity" => %{
            "subject_role" => "driver",
            "subject_user_id" => driver_user_id,
            "chargeable" => true
          }
        }
      })
      |> Repo.insert!()

    _ =
      Events.record_event(ride.id, "offer_missed", now,
        actor_user_id: driver_user_id,
        payload: %{"driver_id" => driver_user_id, "offer_id" => 9_999}
      )

    conn = get(driver_conn, "/api/rides/integrity/me")

    assert %{
             "data" => %{
               "counters" => %{
                 "driver_chargeable_events_7d" => driver_count,
                 "missed_offer_events_24h" => missed_count
               },
               "driver" => %{"tier" => %{"level" => level}}
             }
           } = json_response(conn, 200)

    assert driver_count == 1
    assert missed_count == 1
    assert level in ["normal", "at_risk", "high_risk", "temporary_suspension"]
  end

  defp seed_chargeable_cancel!(user_id, category_id, subject_role, now) do
    %Ride{}
    |> Ride.create_changeset(%{
      "rider_id" => user_id,
      "vehicle_category_id" => category_id,
      "status" => "cancelled",
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "requested_at" => DateTime.add(now, -180, :second),
      "cancelled_at" => DateTime.add(now, -60, :second),
      "cancellation_reason_code" => "rider_changed_mind",
      "cancelled_by_user_id" => user_id,
      "metadata" => %{
        "integrity" => %{
          "subject_role" => subject_role,
          "subject_user_id" => user_id,
          "chargeable" => true
        }
      }
    })
    |> Repo.insert!()
  end

  defp create_eligible_driver_profile!(user_id, category_id) do
    user = Repo.get!(User, user_id)

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ =
      VerificationFixtures.create_driver_location!(driver.user_id,
        lat: Decimal.new("-1.2921000"),
        lng: Decimal.new("36.8219000")
      )

    driver
  end
end
