defmodule Liddr.Rides.SharedRides.Setup do
  @moduledoc false

  alias Liddr.Repo
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRides.StopPlanner

  @default_max_members 2

  def ensure_group_for_ride!(%Ride{} = ride, rider_user_id, now) do
    group =
      %SharedRideGroup{}
      |> SharedRideGroup.create_changeset(%{
        "ride_id" => ride.id,
        "max_members" => @default_max_members,
        "metadata" => %{"product_type" => "shared"}
      })
      |> Repo.insert()
      |> Shared.unwrap_or_rollback()

    fare_kes =
      ride.metadata
      |> Shared.normalize_metadata()
      |> Map.get("quoted_final_fare_kes")

    _member =
      %SharedRideMember{}
      |> SharedRideMember.create_changeset(%{
        "group_id" => group.id,
        "ride_id" => ride.id,
        "rider_user_id" => rider_user_id,
        "status" => "requested",
        "requested_at" => now,
        "fare_kes" => fare_kes,
        "metadata" => %{
          "pickup_lat" => ride.pickup_lat,
          "pickup_lng" => ride.pickup_lng,
          "dropoff_lat" => ride.dropoff_lat,
          "dropoff_lng" => ride.dropoff_lng
        }
      })
      |> Repo.insert()
      |> Shared.unwrap_or_rollback()

    _ = StopPlanner.replan_for_ride!(ride.id, now)

    group
  end
end
