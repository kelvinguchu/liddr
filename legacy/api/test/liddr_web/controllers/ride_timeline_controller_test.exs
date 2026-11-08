defmodule LiddrWeb.RideTimelineControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider and driver can fetch ride details and timeline events", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/driver-arriving", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)

    assert %{"data" => %{"ride" => %{"id" => ^ride_id, "status" => "arrived"}}} =
             get(rider_conn, "/api/rides/#{ride_id}") |> json_response(200)

    assert %{"data" => %{"ride" => %{"id" => ^ride_id, "status" => "arrived"}}} =
             get(driver_conn, "/api/rides/#{ride_id}") |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id},
               "events" => events,
               "next_since" => next_since
             }
           } = get(rider_conn, "/api/rides/#{ride_id}/events") |> json_response(200)

    assert is_binary(next_since)
    event_types = Enum.map(events, & &1["event_type"])
    assert "ride_requested" in event_types
    assert "ride_accepted" in event_types
    assert "driver_arriving" in event_types
    assert "driver_arrived" in event_types
  end

  test "unrelated user cannot fetch ride details or events", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    %{auth_conn: other_rider_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}}} =
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

    assert %{"error" => %{"code" => "RIDE_NOT_ACCESSIBLE"}} =
             get(other_rider_conn, "/api/rides/#{ride_id}") |> json_response(403)

    assert %{"error" => %{"code" => "RIDE_NOT_ACCESSIBLE"}} =
             get(other_rider_conn, "/api/rides/#{ride_id}/events") |> json_response(403)

    assert %{"data" => %{"ride" => %{"id" => ^ride_id}}} =
             get(rider_conn, "/api/rides/#{ride_id}") |> json_response(200)

    assert %{"error" => %{"code" => "RIDE_NOT_ACCESSIBLE"}} =
             get(driver_conn, "/api/rides/#{ride_id}") |> json_response(403)
  end

  test "events endpoint supports incremental fetch with since", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    %{"data" => %{"next_since" => first_cursor}} =
      get(rider_conn, "/api/rides/#{ride_id}/events") |> json_response(200)

    _ = post(driver_conn, "/api/rides/#{ride_id}/driver-arriving", %{}) |> json_response(200)

    assert %{
             "data" => %{
               "events" => [%{"event_type" => "driver_arriving"} | _]
             }
           } =
             get(rider_conn, "/api/rides/#{ride_id}/events?since=#{first_cursor}")
             |> json_response(200)
  end

  test "incidents endpoint returns incident-focused trail", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
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

    _ = post(driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/cancel", %{"reason" => "rider_changed_mind"})
      |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id},
               "incidents" => incidents,
               "summary" => %{"total" => total, "by_event_type" => by_type}
             }
           } = get(rider_conn, "/api/rides/#{ride_id}/incidents") |> json_response(200)

    assert total >= 1
    assert is_list(incidents)
    assert Map.has_key?(by_type, "ride_cancelled")
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
