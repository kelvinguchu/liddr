defmodule LiddrWeb.SharedPoolingRequestTest do
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

  test "shared request joins a compatible existing shared group", %{conn: conn} do
    %{auth_conn: primary_conn, user_id: primary_rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: joining_conn, user_id: joining_rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    %{ride: base_ride, group: group} =
      create_shared_ride_group!(primary_rider_id, category_id,
        pickup_lat: "-1.2921000",
        pickup_lng: "36.8219000",
        dropoff_lat: "-1.3000000",
        dropoff_lng: "36.8000000"
      )

    quote = create_shared_quote!(joining_rider_id, category_id, D.new("170.00"))

    response =
      post_ride_request(joining_conn, %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "quote_id" => quote.id,
        "pickup_lat" => "-1.2922500",
        "pickup_lng" => "36.8219500",
        "dropoff_lat" => "-1.3001200",
        "dropoff_lng" => "36.8001200",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "ride" => %{"id" => returned_ride_id, "product_type" => "shared"},
               "offers_count" => 0,
               "shared_join" => %{"joined" => true, "group_id" => returned_group_id}
             }
           } = json_response(response, 201)

    assert returned_ride_id == base_ride.id
    assert returned_group_id == group.id

    joined_member =
      Repo.one(
        from m in SharedRideMember,
          where: m.group_id == ^group.id and m.rider_user_id == ^joining_rider_id
      )

    assert joined_member
    assert joined_member.ride_id == base_ride.id
    assert D.equal?(joined_member.fare_kes, D.new("170.00"))

    assert %{"data" => %{"ride" => %{"id" => ^returned_ride_id}}} =
             get(joining_conn, "/api/rides/#{returned_ride_id}") |> json_response(200)

    assert %{"data" => %{"rides" => rides}} =
             get(joining_conn, "/api/rides/history/rider") |> json_response(200)

    assert Enum.any?(rides, &(&1["id"] == returned_ride_id))

    assert %{"data" => %{"members" => members, "stops" => stops}} =
             get(primary_conn, "/api/rides/#{returned_ride_id}/shared") |> json_response(200)

    assert Enum.any?(members, &(&1["rider_user_id"] == joining_rider_id))
    assert length(stops) == 4
  end

  test "shared request outside route corridor creates a new shared ride", %{conn: conn} do
    %{user_id: primary_rider_id} = AuthFixtures.authenticate_rider!(conn)
    %{auth_conn: joining_conn, user_id: joining_rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    %{ride: base_ride} =
      create_shared_ride_group!(primary_rider_id, category_id,
        pickup_lat: "-1.3000000",
        pickup_lng: "36.8000000",
        dropoff_lat: "-1.2000000",
        dropoff_lng: "36.8000000"
      )

    response =
      post_ride_request(joining_conn, %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2900000",
        "pickup_lng" => "36.8009000",
        "dropoff_lat" => "-1.2300000",
        "dropoff_lng" => "36.8200000",
        "offer_limit" => 1
      })

    assert %{
             "data" => %{
               "ride" => %{
                 "id" => new_ride_id,
                 "rider_id" => ^joining_rider_id,
                 "product_type" => "shared"
               }
             }
           } = json_response(response, 201)

    refute new_ride_id == base_ride.id

    group =
      Repo.get_by!(SharedRideGroup, ride_id: new_ride_id)

    member =
      Repo.one!(
        from m in SharedRideMember,
          where: m.group_id == ^group.id and m.rider_user_id == ^joining_rider_id
      )

    assert member.ride_id == new_ride_id
    assert member.status == "requested"

    joined_candidate_member_count =
      Repo.aggregate(
        from(m in SharedRideMember, where: m.ride_id == ^base_ride.id),
        :count,
        :id
      )

    assert joined_candidate_member_count == 1
  end

  test "shared request without quote is rejected", %{conn: conn} do
    %{auth_conn: joining_conn, user_id: joining_rider_id} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})

    response =
      post(joining_conn, "/api/rides/requests", %{
        "vehicle_category_id" => category_id,
        "product_type" => "shared",
        "pickup_lat" => "-1.2922500",
        "pickup_lng" => "36.8219500",
        "dropoff_lat" => "-1.3001200",
        "dropoff_lng" => "36.8001200",
        "offer_limit" => 1
      })

    assert %{"error" => %{"code" => "RIDE_QUOTE_REQUIRED"}} = json_response(response, 422)

    assert 0 ==
             Repo.aggregate(
               from(r in Liddr.Rides.Ride, where: r.rider_id == ^joining_rider_id),
               :count,
               :id
             )
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

  defp create_shared_quote!(rider_user_id, category_id, final_fare_kes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RideQuote{}
    |> RideQuote.create_changeset(%{
      "rider_id" => rider_user_id,
      "vehicle_category_id" => category_id,
      "pickup_lat" => D.new("-1.2922500"),
      "pickup_lng" => D.new("36.8219500"),
      "dropoff_lat" => D.new("-1.3001200"),
      "dropoff_lng" => D.new("36.8001200"),
      "distance_m" => 2340,
      "duration_s" => 620,
      "base_amount_kes" => D.new("20.00"),
      "distance_amount_kes" => D.new("40.00"),
      "time_amount_kes" => D.new("10.00"),
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
