defmodule Liddr.Rides.SharedMatcherTest do
  use Liddr.DataCase, async: false

  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedMatcher
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.VerificationFixtures

  test "returns best compatible shared ride by pickup and dropoff proximity" do
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})
    requester = VerificationFixtures.create_user!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    near =
      create_shared_candidate!(category_id,
        pickup_lat: "-1.2921000",
        pickup_lng: "36.8219000",
        dropoff_lat: "-1.3000000",
        dropoff_lng: "36.8000000"
      )

    _far =
      create_shared_candidate!(category_id,
        pickup_lat: "-1.2100000",
        pickup_lng: "36.9200000",
        dropoff_lat: "-1.1000000",
        dropoff_lng: "36.9900000"
      )

    metadata =
      SharedMatcher.match_for_request(
        requester.id,
        category_id,
        %{lat: -1.2922, lng: 36.8218},
        %{lat: -1.3002, lng: 36.8002},
        now
      )

    assert metadata["matched"] == true
    assert metadata["evaluated_candidates_count"] == 2
    assert metadata["compatible_candidates_count"] >= 1
    assert metadata["best_match"]["ride_id"] == near.ride.id
  end

  test "filters out full groups before compatibility scoring" do
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})
    requester = VerificationFixtures.create_user!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _full_group =
      create_shared_candidate!(category_id,
        max_members: 2,
        member_count: 2,
        pickup_lat: "-1.2921000",
        pickup_lng: "36.8219000",
        dropoff_lat: "-1.3000000",
        dropoff_lng: "36.8000000"
      )

    metadata =
      SharedMatcher.match_for_request(
        requester.id,
        category_id,
        %{lat: -1.2922, lng: 36.8218},
        %{lat: -1.3002, lng: 36.8002},
        now
      )

    assert metadata["matched"] == false
    assert metadata["evaluated_candidates_count"] == 0
    assert metadata["compatible_candidates_count"] == 0
    assert is_nil(metadata["best_match"])
  end

  test "rejects candidate when request is outside route corridor" do
    category_id = VerificationFixtures.insert_vehicle_category!(%{slug: "basic"})
    requester = VerificationFixtures.create_user!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _candidate =
      create_shared_candidate!(category_id,
        pickup_lat: "-1.3000000",
        pickup_lng: "36.8000000",
        dropoff_lat: "-1.2000000",
        dropoff_lng: "36.8000000"
      )

    metadata =
      SharedMatcher.match_for_request(
        requester.id,
        category_id,
        %{lat: -1.2900, lng: 36.8009},
        %{lat: -1.2300, lng: 36.8200},
        now
      )

    assert metadata["matched"] == false
    assert metadata["evaluated_candidates_count"] == 1
    assert metadata["compatible_candidates_count"] == 0
    assert is_nil(metadata["best_match"])
  end

  defp create_shared_candidate!(category_id, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    rider = VerificationFixtures.create_user!()
    max_members = Keyword.get(opts, :max_members, 2)
    member_count = Keyword.get(opts, :member_count, 1)

    ride =
      %Ride{}
      |> Ride.create_changeset(%{
        "rider_id" => rider.id,
        "vehicle_category_id" => category_id,
        "status" => "offering",
        "product_type" => "shared",
        "pickup_lat" => Decimal.new(Keyword.fetch!(opts, :pickup_lat)),
        "pickup_lng" => Decimal.new(Keyword.fetch!(opts, :pickup_lng)),
        "dropoff_lat" => Decimal.new(Keyword.fetch!(opts, :dropoff_lat)),
        "dropoff_lng" => Decimal.new(Keyword.fetch!(opts, :dropoff_lng)),
        "requested_at" => now
      })
      |> Repo.insert!()

    group =
      %SharedRideGroup{}
      |> SharedRideGroup.create_changeset(%{
        "ride_id" => ride.id,
        "max_members" => max_members,
        "metadata" => %{}
      })
      |> Repo.insert!()

    Enum.each(1..member_count, fn index ->
      rider_user_id =
        if index == 1 do
          rider.id
        else
          VerificationFixtures.create_user!().id
        end

      %SharedRideMember{}
      |> SharedRideMember.create_changeset(%{
        "group_id" => group.id,
        "ride_id" => ride.id,
        "rider_user_id" => rider_user_id,
        "status" => "requested",
        "requested_at" => now
      })
      |> Repo.insert!()
    end)

    %{ride: ride, group: group}
  end
end
