defmodule LiddrWeb.SharedPoolingDetourGuardTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "shared join is blocked when added member causes excessive detour", %{conn: conn} do
    %{user_id: primary_rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: joining_conn, user_id: joining_rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    %{ride: base_ride} =
      create_shared_ride_group!(primary_rider_id, category_id,
        pickup_lat: "-1.3000000",
        pickup_lng: "36.8000000",
        dropoff_lat: "-1.2900000",
        dropoff_lng: "36.8000000"
      )

    quote =
      create_shared_quote!(joining_rider_id, category_id, D.new("240.00"),
        pickup_lat: "-1.2990000",
        pickup_lng: "36.8000000",
        dropoff_lat: "-1.2500000",
        dropoff_lng: "36.8000000"
      )

    response =
      post(joining_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "quote_id" => quote.id,
        "pickup_lat" => "-1.2990000",
        "pickup_lng" => "36.8000000",
        "dropoff_lat" => "-1.2500000",
        "dropoff_lng" => "36.8000000",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => new_ride_id,
                 "rider_id" => ^joining_rider_id,
                 "quote_id" => quote_id
               }
             }
           } = json_response(response, 201)

    assert quote_id == quote.id
    refute new_ride_id == base_ride.id

    base_member_count =
      Repo.aggregate(
        from(m in SharedRideMember, where: m.ride_id == ^base_ride.id),
        :count,
        :id
      )

    assert base_member_count == 1
  end

  defp create_shared_ride_group!(rider_user_id, category_id, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => rider_user_id,
        "vehicle_category_id" => category_id,
        "status" => "offering",
        "product_type" => "shared",
        "pickup_lat" => D.new(Keyword.fetch!(opts, :pickup_lat)),
        "pickup_lng" => D.new(Keyword.fetch!(opts, :pickup_lng)),
        "dropoff_lat" => D.new(Keyword.fetch!(opts, :dropoff_lat)),
        "dropoff_lng" => D.new(Keyword.fetch!(opts, :dropoff_lng)),
        "requested_at" => now
      })
      |> Repo.insert!()

    group =
      %SharedRideGroup{}
      |> SharedRideGroup.create_changeset(%{"ride_id" => ride.id, "max_members" => 2})
      |> Repo.insert!()

    _member =
      %SharedRideMember{}
      |> SharedRideMember.create_changeset(%{
        "group_id" => group.id,
        "ride_id" => ride.id,
        "rider_user_id" => rider_user_id,
        "status" => "requested",
        "requested_at" => now
      })
      |> Repo.insert!()

    %{ride: ride, group: group}
  end

  defp create_shared_quote!(rider_user_id, category_id, final_fare_kes, coords) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RideQuote{}
    |> RideQuote.create_changeset(%{
      "rider_id" => rider_user_id,
      "vehicle_category_id" => category_id,
      "pickup_lat" => D.new(Keyword.fetch!(coords, :pickup_lat)),
      "pickup_lng" => D.new(Keyword.fetch!(coords, :pickup_lng)),
      "dropoff_lat" => D.new(Keyword.fetch!(coords, :dropoff_lat)),
      "dropoff_lng" => D.new(Keyword.fetch!(coords, :dropoff_lng)),
      "distance_m" => 5200,
      "duration_s" => 900,
      "base_amount_kes" => D.new("50.00"),
      "distance_amount_kes" => D.new("90.00"),
      "time_amount_kes" => D.new("20.00"),
      "min_fare_kes" => D.new("100.00"),
      "surge_multiplier" => D.new("1.00"),
      "subtotal_kes" => final_fare_kes,
      "base_fare_kes" => final_fare_kes,
      "discount_percent" => D.new("0.00"),
      "discount_amount_kes" => D.new("0.00"),
      "final_fare_kes" => final_fare_kes,
      "currency" => "KES",
      "provider" => "google_routes",
      "provider_payload" => %{"product_type" => "shared"},
      "expires_at" => DateTime.add(now, 300, :second)
    })
    |> Repo.insert!()
  end
end
