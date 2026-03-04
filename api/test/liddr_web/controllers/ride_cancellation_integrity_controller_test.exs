defmodule LiddrWeb.RideCancellationIntegrityControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideNotification
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider cancellation requires reason code", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => _offer_id}]}} =
      request_and_accept_ride!(rider_conn, driver_conn, category_id)

    assert %{"error" => %{"code" => "MISSING_CANCEL_REASON"}} =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{}) |> json_response(422)

    assert %{"error" => %{"code" => "INVALID_CANCEL_REASON"}} =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "changed_plans"})
             |> json_response(422)

    assert %{"data" => %{"ride" => %{"status" => "accepted"}}} =
             get(rider_conn, "/api/rides/#{ride_id}") |> json_response(200)
  end

  test "driver can only cancel in-progress ride with emergency/safety reason", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => _offer_id}]}} =
      request_and_accept_ride!(rider_conn, driver_conn, category_id)

    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "DRIVER_CANCEL_REQUIRES_EMERGENCY_REASON"}} =
             post(driver_conn, "/api/rides/#{ride_id}/driver-cancel", %{
               "reason" => "cannot_contact_rider"
             })
             |> json_response(422)

    assert %{"data" => %{"ride" => %{"status" => "cancelled"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/driver-cancel", %{"reason" => "emergency"})
             |> json_response(200)
  end

  test "rider cancellation creates notification rows with socket delivery status sent", %{
    conn: conn
  } do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => _offer_id}]}} =
      request_and_accept_ride!(rider_conn, driver_conn, category_id)

    assert %{
             "data" => %{
               "ride" => %{
                 "status" => "cancelled",
                 "cancellation_reason_code" => "rider_changed_mind"
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "rider_changed_mind"})
             |> json_response(200)

    notifications =
      Repo.all(
        from n in RideNotification,
          where: n.ride_id == ^ride_id and n.event_type == "ride_cancelled",
          order_by: [asc: n.recipient_user_id]
      )

    assert length(notifications) == 2

    assert Enum.map(notifications, & &1.recipient_user_id) == [rider_user_id, driver_user_id]
    assert Enum.all?(notifications, &(&1.socket_status == "sent"))
    assert Enum.all?(notifications, &(&1.push_status == "pending"))
    assert Enum.all?(notifications, &(&1.poll_status == "pending"))
    assert Enum.all?(notifications, &(&1.attempt_count == 1))
  end

  test "fifth chargeable driver cancellation in 7 days triggers temporary suspension", %{
    conn: conn
  } do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(1..4, fn idx ->
      seed_chargeable_driver_cancellation!(
        driver_user_id,
        rider_user_id,
        category_id,
        now,
        idx
      )
    end)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => _offer_id}]}} =
      request_and_accept_ride!(rider_conn, driver_conn, category_id)

    assert %{"data" => %{"ride" => %{"status" => "cancelled"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/driver-cancel", %{
               "reason" => "cannot_contact_rider"
             })
             |> json_response(200)

    user = Repo.get!(User, driver_user_id)
    driver = Repo.get!(Driver, driver_user_id)

    assert user.account_status == "suspended"
    assert driver.account_status == "suspended"
    assert driver.is_available == false
    assert is_nil(driver.current_ride_id)

    enforcement =
      Repo.one!(
        from ue in UserEnforcement,
          where:
            ue.user_id == ^driver_user_id and ue.action == "temporary_suspension" and
              ue.scope == "rides" and ue.status == "active",
          order_by: [desc: ue.id],
          limit: 1
      )

    assert enforcement.reason_code == "driver_chargeable_events_threshold_reached"
    assert DateTime.compare(enforcement.ends_at, now) == :gt
  end

  defp request_and_accept_ride!(rider_conn, driver_conn, category_id) do
    %{"data" => %{"offers" => [%{"id" => offer_id}]}} =
      request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    request_conn
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

  defp seed_chargeable_driver_cancellation!(
         driver_user_id,
         rider_user_id,
         category_id,
         now,
         idx
       ) do
    requested_at = DateTime.add(now, -(idx * 300), :second)
    accepted_at = DateTime.add(requested_at, 30, :second)
    cancelled_at = DateTime.add(accepted_at, 90, :second)

    %Ride{}
    |> Ride.create_changeset(%{
      "rider_id" => rider_user_id,
      "driver_id" => driver_user_id,
      "vehicle_category_id" => category_id,
      "status" => "cancelled",
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "requested_at" => requested_at,
      "accepted_at" => accepted_at,
      "cancelled_at" => cancelled_at,
      "cancellation_reason_code" => "cannot_contact_rider",
      "cancelled_by_user_id" => driver_user_id,
      "metadata" => %{
        "integrity" => %{
          "policy_version" => "ride_integrity_v1",
          "subject_role" => "driver",
          "subject_user_id" => driver_user_id,
          "chargeable" => true
        }
      }
    })
    |> Repo.insert!()
  end
end
