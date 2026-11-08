defmodule Liddr.Rides.SharedMatcher do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedCompatibilityPolicy
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember

  @eligible_ride_statuses ~w(requested offering accepted driver_arriving arrived)
  @active_member_statuses ~w(requested assigned pickup_pending picked_up dropoff_pending)
  @candidate_limit 25

  def match_for_request(
        rider_user_id,
        vehicle_category_id,
        pickup,
        dropoff,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ) do
    request = build_request_coordinates(pickup, dropoff)

    if valid_request_coordinates?(request) do
      candidates = list_candidates(rider_user_id, vehicle_category_id)

      evaluated =
        Enum.flat_map(candidates, fn candidate ->
          case SharedCompatibilityPolicy.evaluate(candidate, request, now) do
            {:ok, score} -> [score]
            {:error, _reason} -> []
          end
        end)

      best =
        case Enum.sort_by(evaluated, &{-&1.score, &1.pickup_distance_m, &1.dropoff_distance_m}) do
          [top | _] -> top
          [] -> nil
        end

      %{
        "strategy" => "shared_v1_proximity",
        "matched" => not is_nil(best),
        "evaluated_candidates_count" => length(candidates),
        "compatible_candidates_count" => length(evaluated),
        "best_match" => serialize_best_match(best)
      }
    else
      %{
        "strategy" => "shared_v1_proximity",
        "matched" => false,
        "evaluated_candidates_count" => 0,
        "compatible_candidates_count" => 0,
        "best_match" => nil,
        "reason_code" => "invalid_request_coordinates"
      }
    end
  end

  defp list_candidates(rider_user_id, vehicle_category_id) do
    query =
      from r in Ride,
        join: g in SharedRideGroup,
        on: g.ride_id == r.id,
        left_join: m in SharedRideMember,
        on: m.group_id == g.id and m.status in ^@active_member_statuses,
        where:
          r.product_type == "shared" and r.vehicle_category_id == ^vehicle_category_id and
            r.status in ^@eligible_ride_statuses and r.rider_id != ^rider_user_id,
        group_by: [
          r.id,
          g.id,
          g.max_members,
          r.pickup_lat,
          r.pickup_lng,
          r.dropoff_lat,
          r.dropoff_lng,
          r.requested_at
        ],
        having: count(m.id) < g.max_members,
        order_by: [desc: r.requested_at, desc: r.id],
        limit: @candidate_limit,
        select: %{
          ride_id: r.id,
          group_id: g.id,
          max_members: g.max_members,
          active_members_count: count(m.id),
          pickup_lat: r.pickup_lat,
          pickup_lng: r.pickup_lng,
          dropoff_lat: r.dropoff_lat,
          dropoff_lng: r.dropoff_lng,
          requested_at: r.requested_at
        }

    query
    |> Repo.all()
    |> Enum.map(fn candidate ->
      open_seats = max(candidate.max_members - candidate.active_members_count, 0)

      candidate
      |> Map.put(:open_seats, open_seats)
      |> Map.put(:pickup_lat, Geo.to_float(candidate.pickup_lat))
      |> Map.put(:pickup_lng, Geo.to_float(candidate.pickup_lng))
      |> Map.put(:dropoff_lat, Geo.to_float(candidate.dropoff_lat))
      |> Map.put(:dropoff_lng, Geo.to_float(candidate.dropoff_lng))
    end)
  end

  defp build_request_coordinates(pickup, dropoff) do
    %{
      pickup_lat: normalize_coordinate(pickup, :lat),
      pickup_lng: normalize_coordinate(pickup, :lng),
      dropoff_lat: normalize_coordinate(dropoff, :lat),
      dropoff_lng: normalize_coordinate(dropoff, :lng)
    }
  end

  defp normalize_coordinate(point, :lat) when is_map(point),
    do: (Map.get(point, :lat) || Map.get(point, "lat")) |> coordinate_to_float()

  defp normalize_coordinate(point, :lng) when is_map(point),
    do: (Map.get(point, :lng) || Map.get(point, "lng")) |> coordinate_to_float()

  defp normalize_coordinate(_point, _key), do: nil

  defp coordinate_to_float(value) when is_integer(value), do: value * 1.0
  defp coordinate_to_float(value) when is_float(value), do: value
  defp coordinate_to_float(%Decimal{} = value), do: Decimal.to_float(value)

  defp coordinate_to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp coordinate_to_float(_value), do: nil

  defp valid_request_coordinates?(request) do
    Enum.all?(
      [request.pickup_lat, request.pickup_lng, request.dropoff_lat, request.dropoff_lng],
      &is_number/1
    )
  end

  defp serialize_best_match(nil), do: nil

  defp serialize_best_match(match) do
    %{
      "ride_id" => match.ride_id,
      "group_id" => match.group_id,
      "score" => match.score,
      "pickup_distance_m" => round(match.pickup_distance_m),
      "dropoff_distance_m" => round(match.dropoff_distance_m),
      "route_pickup_distance_m" => round(match.route_pickup_distance_m),
      "route_dropoff_distance_m" => round(match.route_dropoff_distance_m),
      "pickup_progress" => match.pickup_progress,
      "dropoff_progress" => match.dropoff_progress,
      "age_seconds" => match.age_seconds,
      "open_seats" => match.open_seats
    }
  end
end
