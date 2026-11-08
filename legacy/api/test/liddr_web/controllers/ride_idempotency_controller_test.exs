defmodule LiddrWeb.RideIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideOffer
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/rides/requests replays successful response for identical idempotency key", %{
    conn: conn
  } do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    key = "ride-request-key-001"

    first_conn =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    second_conn =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    assert %{"data" => %{"ride" => %{"id" => first_ride_id}}} = json_response(first_conn, 201)
    assert %{"data" => %{"ride" => %{"id" => second_ride_id}}} = json_response(second_conn, 201)
    assert first_ride_id == second_ride_id

    ride_count =
      Repo.aggregate(from(r in Ride, where: r.rider_id == ^rider_user_id), :count, :id)

    assert ride_count == 1
  end

  test "POST /api/rides/requests returns 409 when idempotency key is reused with different payload",
       %{
         conn: conn
       } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    key = "ride-request-key-002"

    _ =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    mismatch_conn =
      rider_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3500",
        "dropoff_lng" => "36.8500",
        "offer_limit" => 1
      })

    assert %{"error" => %{"code" => "IDEMPOTENCY_KEY_REUSED"}} = json_response(mismatch_conn, 409)
  end

  test "POST /api/rides/offers/:offer_id/accept replays successful response for identical idempotency key",
       %{conn: conn} do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: driver_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    _ = create_eligible_driver_profile!(driver_user_id, category_id)

    request_conn =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000",
        "offer_limit" => 1
      })

    assert %{"data" => %{"offers" => [%{"id" => offer_id}]}} = json_response(request_conn, 201)
    key = "ride-accept-key-001"

    first_accept =
      driver_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/offers/#{offer_id}/accept", %{})

    second_accept =
      driver_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/rides/offers/#{offer_id}/accept", %{})

    assert %{
             "data" => %{"ride" => %{"id" => first_ride_id, "status" => "accepted"}}
           } = json_response(first_accept, 200)

    assert %{
             "data" => %{"ride" => %{"id" => second_ride_id, "status" => "accepted"}}
           } = json_response(second_accept, 200)

    assert first_ride_id == second_ride_id

    accepted_count =
      Repo.aggregate(
        from(o in RideOffer, where: o.id == ^offer_id and o.status == "accepted"),
        :count,
        :id
      )

    assert accepted_count == 1
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
