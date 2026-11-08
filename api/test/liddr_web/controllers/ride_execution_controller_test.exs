defmodule LiddrWeb.RideExecutionControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "driver runs accepted -> arriving -> arrived -> in_progress -> completed", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    assert %{"data" => %{"ride" => %{"status" => "accepted"}}} =
             post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "driver_arriving"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/driver-arriving", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "arrived"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "in_progress"}}} =
             post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{
                 "status" => "completed",
                 "payment_mode" => "mpesa_direct",
                 "final_fare_kes" => "250.00"
               }
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "mpesa_direct",
               "final_fare_kes" => "250.00"
             })
             |> json_response(200)
  end

  test "driver cannot start ride before arrival", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_NOT_STARTABLE"}} =
             post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(422)
  end

  test "rider cancellation unlocks driver for next request", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => ^ride_id,
                 "status" => "cancelled",
                 "cancellation_outcome" => %{
                   "chargeable" => false,
                   "waiver_code" => "rider_free_cancel_window"
                 }
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "rider_changed_mind"})
             |> json_response(200)

    driver = Repo.get!(Driver, driver_user_id)
    assert is_nil(driver.current_ride_id)
    assert driver.dispatch_status == "idle"
    assert driver.is_available == true

    assert %{"data" => %{"offers_count" => 1}} =
             post_ride_request(rider_conn, %{
               "vehicle_category_id" => category_id,
               "pickup_lat" => "-1.2921",
               "pickup_lng" => "36.8219",
               "dropoff_lat" => "-1.3000",
               "dropoff_lng" => "36.8000",
               "offer_limit" => 1
             })
             |> json_response(201)
  end

  test "driver no-show is only allowed after arrival", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_NOT_NO_SHOW_ELIGIBLE"}} =
             post(driver_conn, "/api/rides/#{ride_id}/no-show", %{}) |> json_response(422)

    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_NO_SHOW_WAIT_NOT_ELAPSED"}} =
             post(driver_conn, "/api/rides/#{ride_id}/no-show", %{}) |> json_response(422)

    wait_seconds = Liddr.Rides.Execution.GeoPolicy.no_show_wait_seconds()
    arrived_at = DateTime.utc_now() |> DateTime.add(-(wait_seconds + 5), :second)

    _ =
      Repo.update_all(
        from(r in Ride, where: r.id == ^ride_id),
        set: [arrived_at: arrived_at]
      )

    assert %{
             "data" => %{
               "ride" => %{
                 "status" => "cancelled",
                 "cancellation_outcome" => %{
                   "chargeable" => true,
                   "reason_code" => "rider_no_show"
                 }
               }
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/no-show", %{}) |> json_response(200)
  end

  test "completion requires payment_mode", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "INVALID_PAYMENT_MODE"}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{"final_fare_kes" => "180"})
             |> json_response(422)
  end

  test "completion enforces requested payment_mode policy when rider requested prepay", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "payment_mode" => "in_app_mpesa",
        "offer_limit" => 1
      })
      |> json_response(201)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/drivers/me/location", %{"lat" => "-1.3000", "lng" => "36.8000"})

    assert %{"error" => %{"code" => "PAYMENT_MODE_POLICY_MISMATCH"}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "cash_direct",
               "final_fare_kes" => "250.00"
             })
             |> json_response(422)
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
