defmodule LiddrWeb.RideReassignControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "rider can reassign when pickup-health recommends reassign", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)

    %{auth_conn: first_driver_conn, user_id: first_driver_id} =
      AuthFixtures.authenticate_driver!(conn)

    %{user_id: second_driver_id} = AuthFixtures.authenticate_driver!(conn)
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
        Decimal.new("-1.2928000"),
        Decimal.new("36.8225000")
      )

    %{"data" => %{"ride" => %{"id" => ride_id}, "offers" => [%{"id" => offer_id}]}} =
      rider_conn
      |> post_ride_request(%{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1,
        "offer_ttl_seconds" => 30
      })
      |> json_response(201)

    _ = post(first_driver_conn, "/api/rides/offers/#{offer_id}/accept", %{}) |> json_response(200)

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
        from(dl in Liddr.Location.DriverLocation, where: dl.driver_id == ^first_driver_id),
        set: [
          lat: Decimal.new("-1.3500000"),
          lng: Decimal.new("36.9000000"),
          captured_at: now
        ]
      )

    assert %{
             "data" => %{
               "pickup_health" => %{
                 "recommend_reassign" => true,
                 "recommendation_reason_code" => reason_code
               }
             }
           } =
             get(rider_conn, "/api/rides/#{ride_id}/pickup-health")
             |> json_response(200)

    assert reason_code in ["driver_moving_away", "driver_no_progress", "driver_late"]

    assert %{
             "data" => %{
               "ride" => %{"id" => ^ride_id, "status" => "offering", "driver_id" => nil}
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/reassign", %{"reason" => "driver_not_moving"})
             |> json_response(200)

    first_driver = Repo.get!(Driver, first_driver_id)
    assert first_driver.dispatch_status == "idle"
    assert is_nil(first_driver.current_ride_id)
    assert first_driver.is_available == true

    statuses =
      Repo.all(
        from o in RideOffer,
          where: o.ride_id == ^ride_id,
          select: {o.driver_id, o.status}
      )

    assert {first_driver_id, "withdrawn"} in statuses
    assert {second_driver_id, "offered"} in statuses
  end

  test "rider cannot reassign when pickup-health does not recommend", %{conn: conn} do
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

    assert %{"error" => %{"code" => "REASSIGN_NOT_RECOMMENDED"}} =
             post(rider_conn, "/api/rides/#{ride_id}/reassign", %{}) |> json_response(422)
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
