defmodule Liddr.Rides.SharedRides.StopOptimizer do
  @moduledoc false

  alias Liddr.Rides.Geo

  def order_stops(start_point, stops, picked_member_ids \\ MapSet.new())
      when is_list(stops) and is_map(picked_member_ids) do
    do_order(start_point, stops, picked_member_ids, [])
  end

  defp do_order(_current_point, [], _picked_member_ids, acc), do: Enum.reverse(acc)

  defp do_order(current_point, remaining, picked_member_ids, acc) do
    feasible = Enum.filter(remaining, &feasible_stop?(&1, picked_member_ids))

    case choose_next_stop(current_point, feasible) do
      nil ->
        Enum.reverse(acc) ++ remaining

      next_stop ->
        next_point = {next_stop.lat, next_stop.lng}
        next_picked_ids = mark_pickup(next_stop, picked_member_ids)
        next_remaining = remove_stop(remaining, next_stop)
        do_order(next_point, next_remaining, next_picked_ids, [next_stop | acc])
    end
  end

  defp feasible_stop?(%{stop_type: "pickup"}, _picked_member_ids), do: true

  defp feasible_stop?(%{stop_type: "dropoff", member_id: member_id}, picked_member_ids),
    do: MapSet.member?(picked_member_ids, member_id)

  defp feasible_stop?(_stop, _picked_member_ids), do: false

  defp choose_next_stop(_current_point, []), do: nil

  defp choose_next_stop(current_point, feasible_stops) do
    Enum.min_by(feasible_stops, &sort_key(current_point, &1))
  end

  defp sort_key({current_lat, current_lng}, stop) do
    distance = Geo.haversine_distance_m(current_lat, current_lng, stop.lat, stop.lng)
    stop_type_rank = if stop.stop_type == "pickup", do: 0, else: 1
    {distance, stop_type_rank, stop.requested_at, stop.member_id}
  end

  defp mark_pickup(%{stop_type: "pickup", member_id: member_id}, picked_member_ids),
    do: MapSet.put(picked_member_ids, member_id)

  defp mark_pickup(_stop, picked_member_ids), do: picked_member_ids

  defp remove_stop(stops, stop) do
    Enum.reject(stops, fn candidate -> candidate.stop_key == stop.stop_key end)
  end
end
