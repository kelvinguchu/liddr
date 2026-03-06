defmodule LiddrWeb.RideCurrentStatusControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider and driver get compact current trip status projection", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        driver_user_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

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

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "accepted"},
               "current_trip_status" => %{
                 "current_stage" => "driver_assigned",
                 "recommended_action" => "prepare_for_pickup",
                 "latest_status_event" => %{"event_type" => "ride_accepted"},
                 "is_terminal" => false
               }
             }
           } = get(rider_conn, "/api/rides/#{ride_id}/current-status") |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "accepted"},
               "current_trip_status" => %{"current_stage" => "driver_assigned"}
             }
           } = get(driver_conn, "/api/rides/#{ride_id}/current-status") |> json_response(200)
  end

  test "current trip status exposes reassign context and latest new_driver_found signal", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: first_driver_conn, user_id: first_driver_id} =
      AuthFixtures.authenticate_driver!(conn)

    %{auth_conn: second_driver_conn, user_id: second_driver_id} =
      AuthFixtures.authenticate_driver!(conn)

    category_id = VerificationFixtures.insert_vehicle_category!()

    _ =
      create_eligible_driver_profile!(
        first_driver_id,
        category_id,
        Decimal.new("-1.2921000"),
        Decimal.new("36.8219000")
      )

    _ =
      create_eligible_driver_profile!(
        second_driver_id,
        category_id,
        Decimal.new("-1.3200000"),
        Decimal.new("36.8600000")
      )

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => first_offer_id}]}} =
      rider_conn
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 30
      })
      |> json_response(201)

    _ =
      post(first_driver_conn, "/api/rides/offers/#{first_offer_id}/accept", %{})
      |> json_response(200)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Repo.update_all(
        from(r in Ride, where: r.id == ^ride_id),
        set: [
          accepted_at: DateTime.add(now, -500, :second),
          metadata: %{
            "driver_distance_to_pickup_m_at_accept" => 100,
            "promised_pickup_eta_s_at_accept" => 60
          }
        ]
      )

    _ =
      Repo.update_all(
        from(dl in DriverLocation, where: dl.driver_id == ^first_driver_id),
        set: [lat: Decimal.new("-1.3500000"), lng: Decimal.new("36.9000000"), captured_at: now]
      )

    _ =
      post(rider_conn, "/api/rides/#{ride_id}/reassign", %{"reason" => "driver_not_moving"})
      |> json_response(200)

    %{"data" => %{"offers" => offers}} =
      get(second_driver_conn, "/api/rides/offers") |> json_response(200)

    matching_offer =
      Enum.find(offers, fn offer ->
        get_in(offer, ["ride", "id"]) == ride_id and
          get_in(offer, ["offer", "status"]) == "offered"
      end)

    assert is_map(matching_offer)
    second_offer_id = get_in(matching_offer, ["offer", "id"])

    _ =
      post(second_driver_conn, "/api/rides/offers/#{second_offer_id}/accept", %{})
      |> json_response(200)

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "accepted"},
               "current_trip_status" => %{
                 "current_stage" => "driver_assigned",
                 "latest_status_event" => %{"event_type" => "new_driver_found"},
                 "reassign_context" => %{
                   "reassign_count" => 1,
                   "last_reassign_driver_id" => ^first_driver_id
                 }
               }
             }
           } = get(rider_conn, "/api/rides/#{ride_id}/current-status") |> json_response(200)
  end

  defp create_eligible_driver_profile!(user_id, category_id, lat, lng) do
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

    _ = VerificationFixtures.create_driver_location!(driver.user_id, lat: lat, lng: lng)
    driver
  end
end
