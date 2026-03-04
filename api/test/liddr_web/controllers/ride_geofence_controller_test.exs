defmodule LiddrWeb.RideGeofenceControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "driver cannot mark arrived when too far from pickup", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_driver_profile!(driver_user_id, category_id,
        lat: Decimal.new("-1.3020000"),
        lng: Decimal.new("36.8290000")
      )

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "DRIVER_TOO_FAR_FROM_PICKUP"}} =
             post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(422)
  end

  test "driver cannot complete when too far from dropoff", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    assert %{"error" => %{"code" => "DRIVER_TOO_FAR_FROM_DROPOFF"}} =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "mpesa_direct",
               "final_fare_kes" => "220.00"
             })
             |> json_response(422)
  end

  test "arrived and completed ride stores distance metrics when geofence passes", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      request_ride!(rider_conn, category_id)

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"status" => "arrived", "arrival_distance_m" => arrival_m}}} =
             post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert is_integer(arrival_m)

    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"status" => "completed", "completion_distance_m" => completion_m}
             }
           } =
             post(driver_conn, "/api/rides/#{ride_id}/complete", %{
               "payment_mode" => "mpesa_direct",
               "final_fare_kes" => "220.00"
             })
             |> json_response(200)

    assert is_integer(completion_m)
  end

  defp request_ride!(rider_conn, category_id) do
    rider_conn
    |> post("/api/rides/requests", %{
      "vehicle_category_id" => category_id,
      "pickup_lat" => "-1.2921",
      "pickup_lng" => "36.8219",
      "dropoff_lat" => "-1.3000",
      "dropoff_lng" => "36.8000",
      "offer_limit" => 1
    })
    |> json_response(201)
  end

  defp create_driver_profile!(user_id, category_id, opts \\ []) do
    user = Repo.get!(User, user_id)
    lat = Keyword.get(opts, :lat, Decimal.new("-1.2921000"))
    lng = Keyword.get(opts, :lng, Decimal.new("36.8219000"))

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    _ = VerificationFixtures.create_driver_location!(driver.user_id, lat: lat, lng: lng)
    driver
  end
end
