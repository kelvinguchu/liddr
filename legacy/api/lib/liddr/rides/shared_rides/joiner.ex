defmodule Liddr.Rides.SharedRides.Joiner do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideQuote
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRides.DetourGuard
  alias Liddr.Rides.SharedRides.StopPlanner

  @joinable_ride_statuses ~w(requested offering accepted driver_arriving arrived)
  @active_member_statuses ~w(requested assigned pickup_pending picked_up dropoff_pending)

  def try_join_existing_group!(
        rider_user_id,
        category_id,
        pickup_point,
        dropoff_point,
        quote,
        shared_match_metadata,
        now
      ) do
    if is_nil(quote) do
      :no_join
    else
      case matched_ride_id(shared_match_metadata) do
        nil ->
          :no_join

        matched_ride_id ->
          maybe_join(
            rider_user_id,
            category_id,
            matched_ride_id,
            pickup_point,
            dropoff_point,
            quote,
            shared_match_metadata,
            now
          )
      end
    end
  end

  defp maybe_join(
         rider_user_id,
         category_id,
         ride_id,
         pickup_point,
         dropoff_point,
         quote,
         shared_match_metadata,
         now
       ) do
    with {:ok, ride} <- fetch_joinable_ride(ride_id, category_id),
         {:ok, group} <- fetch_group_for_ride(ride.id),
         :ok <- ensure_group_has_capacity(group.id, group.max_members),
         {:ok, member} <-
           upsert_member(
             group,
             ride,
             rider_user_id,
             pickup_point,
             dropoff_point,
             quote,
             shared_match_metadata,
             now
           ) do
      _ = StopPlanner.replan_for_ride!(ride.id, now)
      %{ride: ride, group: group, member: member}
    else
      _ -> :no_join
    end
  end

  defp fetch_joinable_ride(ride_id, category_id) do
    ride =
      Repo.one(
        from r in Ride,
          where:
            r.id == ^ride_id and r.product_type == "shared" and
              r.vehicle_category_id == ^category_id and
              r.status in ^@joinable_ride_statuses,
          lock: "FOR UPDATE",
          limit: 1
      )

    if is_nil(ride), do: {:error, :ride_not_joinable}, else: {:ok, ride}
  end

  defp fetch_group_for_ride(ride_id) do
    group =
      Repo.one(
        from g in SharedRideGroup,
          where: g.ride_id == ^ride_id,
          lock: "FOR UPDATE",
          limit: 1
      )

    if is_nil(group), do: {:error, :shared_group_not_found}, else: {:ok, group}
  end

  defp ensure_group_has_capacity(group_id, max_members) do
    active_members_count =
      Repo.one(
        from m in SharedRideMember,
          where: m.group_id == ^group_id and m.status in ^@active_member_statuses,
          select: count(m.id)
      ) || 0

    if active_members_count < max_members, do: :ok, else: {:error, :shared_group_full}
  end

  defp upsert_member(
         group,
         ride,
         rider_user_id,
         pickup_point,
         dropoff_point,
         quote,
         shared_match_metadata,
         now
       ) do
    existing_member =
      Repo.one(
        from m in SharedRideMember,
          where: m.group_id == ^group.id and m.rider_user_id == ^rider_user_id,
          lock: "FOR UPDATE",
          limit: 1
      )

    if existing_member do
      {:ok, existing_member}
    else
      metadata =
        build_member_metadata(
          ride.id,
          pickup_point,
          dropoff_point,
          ride,
          shared_match_metadata
        )

      candidate_member =
        build_candidate_member(
          rider_user_id,
          initial_member_status(ride.status),
          metadata,
          now
        )

      with :ok <- ensure_join_detour_viable(ride, group.id, candidate_member) do
        member =
          %SharedRideMember{}
          |> SharedRideMember.create_changeset(%{
            "group_id" => group.id,
            "ride_id" => ride.id,
            "rider_user_id" => rider_user_id,
            "status" => candidate_member.status,
            "requested_at" => now,
            "fare_kes" => quote_fare(quote),
            "metadata" => candidate_member.metadata
          })
          |> Repo.insert()
          |> unwrap_or_rollback()

        _ =
          Events.record_event(ride.id, "shared_member_joined", now,
            actor_user_id: rider_user_id,
            payload: %{
              "shared_member_id" => member.id,
              "shared_group_id" => group.id,
              "joined_via_match" => true
            }
          )
          |> unwrap_or_rollback()

        {:ok, member}
      end
    end
  end

  defp ensure_join_detour_viable(ride, group_id, candidate_member) do
    current_members =
      Repo.all(
        from m in SharedRideMember,
          where: m.group_id == ^group_id and m.status in ^@active_member_statuses
      )

    DetourGuard.ensure_join_viable(ride, current_members, candidate_member)
  end

  defp build_candidate_member(rider_user_id, status, metadata, now) do
    %{
      id: 0,
      rider_user_id: rider_user_id,
      status: status,
      requested_at: now,
      metadata: metadata
    }
  end

  defp quote_fare(%RideQuote{final_fare_kes: fare_kes}), do: fare_kes
  defp quote_fare(_quote), do: nil

  defp build_member_metadata(
         ride_id,
         pickup_point,
         dropoff_point,
         ride,
         shared_match_metadata
       ) do
    best_match = normalized_best_match(shared_match_metadata)

    %{
      "joined_via" => "shared_match",
      "matched_ride_id" => ride_id,
      "match_score" => Map.get(best_match, "score"),
      "pickup_distance_m" => Map.get(best_match, "pickup_distance_m"),
      "dropoff_distance_m" => Map.get(best_match, "dropoff_distance_m"),
      "pickup_lat" => pickup_value(pickup_point, :lat, ride.pickup_lat),
      "pickup_lng" => pickup_value(pickup_point, :lng, ride.pickup_lng),
      "dropoff_lat" => pickup_value(dropoff_point, :lat, ride.dropoff_lat),
      "dropoff_lng" => pickup_value(dropoff_point, :lng, ride.dropoff_lng)
    }
  end

  defp pickup_value(point, key, fallback) when is_map(point) do
    case Map.get(point, key) do
      nil -> fallback
      value -> value
    end
  end

  defp pickup_value(_point, _key, fallback), do: fallback

  defp normalized_best_match(%{"best_match" => %{} = best_match}), do: best_match
  defp normalized_best_match(%{best_match: %{} = best_match}), do: best_match
  defp normalized_best_match(_), do: %{}

  defp matched_ride_id(%{"matched" => true, "best_match" => %{"ride_id" => ride_id}}),
    do: parse_positive_integer(ride_id)

  defp matched_ride_id(%{matched: true, best_match: %{ride_id: ride_id}}),
    do: parse_positive_integer(ride_id)

  defp matched_ride_id(_), do: nil

  defp initial_member_status(status) when status in ["requested", "offering"], do: "requested"

  defp initial_member_status(status) when status in ["accepted", "driver_arriving"],
    do: "assigned"

  defp initial_member_status("arrived"), do: "pickup_pending"
  defp initial_member_status(_status), do: "requested"

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
