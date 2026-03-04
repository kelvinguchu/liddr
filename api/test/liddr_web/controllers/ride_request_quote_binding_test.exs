defmodule LiddrWeb.RideRequestQuoteBindingTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.RideQuote
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

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
      post(rider_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "quote_id" => quote.id
      })

    assert %{"data" => %{"ride" => %{"quote_id" => returned_quote_id}}} =
             json_response(request_conn, 201)

    assert returned_quote_id == quote.id
  end
end
