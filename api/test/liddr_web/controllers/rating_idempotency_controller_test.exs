defmodule LiddrWeb.RatingIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.RatingAction
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/rides/:ride_id/rate replays successful response for identical idempotency key",
       %{
         conn: conn
       } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)
    key = "rate-#{System.unique_integer([:positive])}"

    first =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/rate", %{"score" => 5})
      |> json_response(201)

    second =
      rider_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/rate", %{"score" => 5})
      |> json_response(201)

    assert get_in(first, ["data", "rating", "id"]) == get_in(second, ["data", "rating", "id"])
    assert Repo.aggregate(from(r in Rating, where: r.ride_id == ^ride_id), :count, :id) == 1
  end

  test "POST /api/rides/:ride_id/rate/skip replays successful response for identical idempotency key",
       %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _driver = create_eligible_driver_profile!(driver_user_id, category_id)
    ride_id = create_completed_ride!(rider_conn, driver_conn, category_id)
    key = "rate-skip-#{System.unique_integer([:positive])}"

    first =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/rate/skip", %{})
      |> json_response(200)

    second =
      rider_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/#{ride_id}/rate/skip", %{})
      |> json_response(200)

    assert first == second
    assert Repo.aggregate(from(r in Rating, where: r.ride_id == ^ride_id), :count, :id) == 0

    assert Repo.aggregate(
             from(a in RatingAction,
               where: a.ride_id == ^ride_id and a.status == "skipped"
             ),
             :count,
             :id
           ) == 1
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
        lat: D.new("-1.2921000"),
        lng: D.new("36.8219000")
      )

    driver
  end
end
