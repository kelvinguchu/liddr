defmodule LiddrWeb.RideIntegrityPolicyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "prepay-only rider must request with in_app_mpesa payment_mode", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    enable_prepay_only!(rider_user_id, 7)

    assert %{"error" => %{"code" => "RIDER_PREPAY_REQUIRED"}} =
             post(rider_conn, "/api/rides/requests", %{
               "vehicle_category_id" => category_id,
               "pickup_lat" => "-1.2921",
               "pickup_lng" => "36.8219",
               "dropoff_lat" => "-1.3000",
               "dropoff_lng" => "36.8000",
               "offer_limit" => 1
             })
             |> json_response(422)

    assert %{"data" => %{"ride" => %{"id" => ride_id}}} =
             post(rider_conn, "/api/rides/requests", %{
               "vehicle_category_id" => category_id,
               "pickup_lat" => "-1.2921",
               "pickup_lng" => "36.8219",
               "dropoff_lat" => "-1.3000",
               "dropoff_lng" => "36.8000",
               "payment_mode" => "in_app_mpesa",
               "offer_limit" => 1
             })
             |> json_response(201)

    ride = Repo.get!(Ride, ride_id)
    assert ride.metadata["requested_payment_mode"] == "in_app_mpesa"
  end

  test "fifth chargeable rider cancellation in 7 days enables prepay-only mode", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(1..4, fn idx ->
      seed_chargeable_rider_cancellation!(rider_user_id, category_id, now, idx)
    end)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    accepted_at = DateTime.add(now, -240, :second)

    _ =
      Repo.update_all(
        from(r in Ride, where: r.id == ^ride_id),
        set: [accepted_at: accepted_at, metadata: %{}, updated_at: now]
      )

    assert %{"data" => %{"ride" => %{"status" => "cancelled"}}} =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "rider_changed_mind"})
             |> json_response(200)

    rider = Repo.get!(User, rider_user_id)
    assert rider.ride_booking_mode == "prepay_only"
    assert DateTime.compare(rider.ride_booking_mode_until, now) == :gt

    _ = request_conn
  end

  test "waived rider cancellation does not push rider into prepay-only mode", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(1..4, fn idx ->
      seed_chargeable_rider_cancellation!(rider_user_id, category_id, now, idx)
    end)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    assert %{"data" => %{"ride" => %{"status" => "cancelled"}}} =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "rider_changed_mind"})
             |> json_response(200)

    rider = Repo.get!(User, rider_user_id)
    assert rider.ride_booking_mode in [nil, "normal"]
    assert is_nil(rider.ride_booking_mode_until)

    _ = request_conn
  end

  defp seed_chargeable_rider_cancellation!(rider_user_id, category_id, now, idx) do
    requested_at = DateTime.add(now, -(idx * 300), :second)
    cancelled_at = DateTime.add(requested_at, 120, :second)

    %Ride{}
    |> Ride.create_changeset(%{
      "rider_id" => rider_user_id,
      "vehicle_category_id" => category_id,
      "status" => "cancelled",
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "requested_at" => requested_at,
      "cancelled_at" => cancelled_at,
      "cancellation_reason_code" => "rider_changed_mind",
      "cancelled_by_user_id" => rider_user_id,
      "metadata" => %{
        "integrity" => %{
          "policy_version" => "ride_integrity_v1",
          "subject_role" => "rider",
          "subject_user_id" => rider_user_id,
          "chargeable" => true
        }
      }
    })
    |> Repo.insert!()
  end

  defp enable_prepay_only!(rider_user_id, days) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rider = Repo.get!(User, rider_user_id)

    rider
    |> User.ride_booking_mode_changeset(%{
      "ride_booking_mode" => "prepay_only",
      "ride_booking_mode_until" => DateTime.add(now, days * 86_400, :second)
    })
    |> Repo.update!()
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

    driver = Repo.get!(Driver, driver.user_id)
    driver
  end
end
