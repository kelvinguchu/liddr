defmodule LiddrWeb.RatingControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.RatingAction
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "completed rides create pending rating actions for rider and driver", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{"data" => %{"pending_ratings" => [rider_action]}} =
             get(rider_conn, "/api/ratings/me/pending") |> json_response(200)

    assert rider_action["ride_id"] == ride_id
    assert rider_action["rated_user_id"] == driver_user_id

    assert %{"data" => %{"pending_ratings" => [driver_action]}} =
             get(driver_conn, "/api/ratings/me/pending") |> json_response(200)

    assert driver_action["ride_id"] == ride_id
    assert driver_action["rated_user_id"] == rider_user_id
  end

  test "rating below five stars requires reason tags", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{"error" => %{"code" => "MISSING_RATING_REASONS"}} =
             post(rider_conn, "/api/rides/#{ride_id}/rate", %{"score" => 1})
             |> json_response(422)
  end

  test "non-attributable low rating is recorded but excluded from score", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{
             "data" => %{
               "rating" => %{
                 "score" => 1,
                 "include_in_score" => false,
                 "exclusion_reason_code" => "out_of_control_factor"
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/rate", %{
               "score" => 1,
               "reason_tags" => ["traffic"]
             })
             |> json_response(201)

    driver_user = Repo.get!(User, driver_user_id)
    assert driver_user.rating_count == 0
    assert is_nil(driver_user.rating_score)
  end

  test "non-attributable reason tags are case-insensitive", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{
             "data" => %{
               "rating" => %{
                 "score" => 1,
                 "include_in_score" => false,
                 "exclusion_reason_code" => "out_of_control_factor"
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/rate", %{
               "score" => 1,
               "reason_tags" => ["Traffic"]
             })
             |> json_response(201)

    driver_user = Repo.get!(User, driver_user_id)
    assert driver_user.rating_count == 0
    assert is_nil(driver_user.rating_score)
  end

  test "rating can be submitted once and then action closes", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{
             "data" => %{
               "rating" => %{
                 "ride_id" => ^ride_id,
                 "rated_by_user_id" => ^rider_user_id,
                 "rated_user_id" => ^driver_user_id,
                 "score" => 5,
                 "include_in_score" => true
               }
             }
           } =
             post(rider_conn, "/api/rides/#{ride_id}/rate", %{
               "score" => 5
             })
             |> json_response(201)

    assert %{"error" => %{"code" => "RATING_NOT_PENDING"}} =
             post(rider_conn, "/api/rides/#{ride_id}/rate", %{"score" => 5})
             |> json_response(422)

    assert %{"data" => %{"pending_ratings" => []}} =
             get(rider_conn, "/api/ratings/me/pending") |> json_response(200)
  end

  test "pending rating can be skipped explicitly", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)

    assert %{"data" => %{"ride_id" => ^ride_id, "rating_action_status" => "skipped"}} =
             post(rider_conn, "/api/rides/#{ride_id}/rate/skip", %{}) |> json_response(200)

    assert %{"data" => %{"pending_ratings" => []}} =
             get(rider_conn, "/api/ratings/me/pending") |> json_response(200)
  end

  test "rating events are written to ride timeline", %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    ride_for_rate = create_completed_ride!(rider_conn, driver_conn, category_id)
    ride_for_skip = create_completed_ride!(rider_conn, driver_conn, category_id)

    _ =
      post(rider_conn, "/api/rides/#{ride_for_rate}/rate", %{"score" => 5}) |> json_response(201)

    _ = post(rider_conn, "/api/rides/#{ride_for_skip}/rate/skip", %{}) |> json_response(200)

    assert %{"data" => %{"events" => rated_events}} =
             get(rider_conn, "/api/rides/#{ride_for_rate}/events") |> json_response(200)

    rated_event_types = Enum.map(rated_events, & &1["event_type"])
    assert "ride_rating_pending" in rated_event_types
    assert "ride_rated" in rated_event_types

    assert %{"data" => %{"events" => skipped_events}} =
             get(rider_conn, "/api/rides/#{ride_for_skip}/events") |> json_response(200)

    skipped_event_types = Enum.map(skipped_events, & &1["event_type"])
    assert "ride_rating_pending" in skipped_event_types
    assert "ride_rating_skipped" in skipped_event_types
  end

  defp create_completed_ride!(rider_conn, driver_conn, category_id) do
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

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.2921",
        "lng" => "36.8219"
      })
      |> json_response(200)

    _ = post(driver_conn, "/api/rides/#{ride_id}/arrived", %{}) |> json_response(200)
    _ = post(driver_conn, "/api/rides/#{ride_id}/start", %{}) |> json_response(200)

    _ =
      post(driver_conn, "/api/drivers/me/location", %{
        "lat" => "-1.3000",
        "lng" => "36.8000"
      })
      |> json_response(200)

    _ =
      post(driver_conn, "/api/rides/#{ride_id}/complete", %{
        "payment_mode" => "mpesa_direct",
        "final_fare_kes" => "250.00"
      })
      |> json_response(200)

    assert Repo.aggregate(from(r in RatingAction, where: r.ride_id == ^ride_id), :count, :id) == 2
    assert Repo.aggregate(from(r in Rating, where: r.ride_id == ^ride_id), :count, :id) == 0
    ride_id
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
