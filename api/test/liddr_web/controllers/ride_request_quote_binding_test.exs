defmodule LiddrWeb.RideRequestQuoteBindingTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideQuote
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/rides/requests rejects a booking without a quote", %{conn: conn} do
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    response =
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "pickup_lat" => "-1.2921",
        "pickup_lng" => "36.8219",
        "dropoff_lat" => "-1.3000",
        "dropoff_lng" => "36.8000"
      })

    assert %{"error" => %{"code" => "RIDE_QUOTE_REQUIRED"}} = json_response(response, 422)
    assert is_nil(Repo.get_by(Ride, rider_id: rider_user_id))
  end

  test "POST /api/rides/requests links valid quote_id to ride", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    quote =
      %RideQuote{}
      |> RideQuote.create_changeset(%{
        "rider_id" => rider_user_id,
        "vehicle_category_id" => category_id,
        "pickup_lat" => D.new("-1.2921000"),
        "pickup_lng" => D.new("36.8219000"),
        "dropoff_lat" => D.new("-1.3000000"),
        "dropoff_lng" => D.new("36.8000000"),
        "distance_m" => 2340,
        "duration_s" => 620,
        "base_amount_kes" => D.new("20.00"),
        "distance_amount_kes" => D.new("40.00"),
        "time_amount_kes" => D.new("10.00"),
        "min_fare_kes" => D.new("100.00"),
        "surge_multiplier" => D.new("1.00"),
        "subtotal_kes" => D.new("100.00"),
        "base_fare_kes" => D.new("100.00"),
        "discount_percent" => D.new("0.00"),
        "discount_amount_kes" => D.new("0.00"),
        "final_fare_kes" => D.new("100.00"),
        "currency" => "KES",
        "provider" => "google_routes",
        "expires_at" => DateTime.add(now, 300, :second)
      })
      |> Repo.insert!()

    request_conn =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "quote_id" => quote.id
      })

    assert %{"data" => %{"ride" => %{"quote_id" => returned_quote_id}}} =
             json_response(request_conn, 201)

    assert returned_quote_id == quote.id
  end

  test "POST /api/rides/requests enforces quote product_type compatibility", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{auth_conn: rider_conn, user_id: rider_user_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    shared_quote =
      %RideQuote{}
      |> RideQuote.create_changeset(%{
        "rider_id" => rider_user_id,
        "vehicle_category_id" => category_id,
        "pickup_lat" => D.new("-1.2921000"),
        "pickup_lng" => D.new("36.8219000"),
        "dropoff_lat" => D.new("-1.3000000"),
        "dropoff_lng" => D.new("36.8000000"),
        "distance_m" => 2340,
        "duration_s" => 620,
        "base_amount_kes" => D.new("20.00"),
        "distance_amount_kes" => D.new("40.00"),
        "time_amount_kes" => D.new("10.00"),
        "min_fare_kes" => D.new("100.00"),
        "surge_multiplier" => D.new("1.00"),
        "subtotal_kes" => D.new("100.00"),
        "base_fare_kes" => D.new("100.00"),
        "discount_percent" => D.new("10.00"),
        "discount_amount_kes" => D.new("10.00"),
        "final_fare_kes" => D.new("90.00"),
        "currency" => "KES",
        "provider" => "google_routes",
        "provider_payload" => %{"product_type" => "shared"},
        "expires_at" => DateTime.add(now, 300, :second)
      })
      |> Repo.insert!()

    mismatch_conn =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "quote_id" => shared_quote.id
      })

    assert %{"error" => %{"code" => "RIDE_QUOTE_PRODUCT_TYPE_MISMATCH"}} =
             json_response(mismatch_conn, 422)

    valid_conn =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "quote_id" => shared_quote.id
      })

    assert %{
             "data" => %{
               "ride" => %{
                 "quote_id" => returned_quote_id,
                 "product_type" => "shared"
               }
             }
           } = json_response(valid_conn, 201)

    assert returned_quote_id == shared_quote.id
  end

  test "POST /api/rides/requests with shared product_type stores shared_match metadata", %{
    conn: conn
  } do
    %{auth_conn: rider_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    request_conn =
      post_ride_request(rider_conn, %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2922",
        "pickup_lng" => "36.8218",
        "dropoff_lat" => "-1.3002",
        "dropoff_lng" => "36.8002",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => ride_id, "product_type" => "shared"}
             }
           } = json_response(request_conn, 201)

    ride = Repo.get!(Ride, ride_id)
    assert %{"shared_match" => match_metadata} = ride.metadata
    assert match_metadata["matched"] == false
    assert is_nil(match_metadata["best_match"])
  end
end
