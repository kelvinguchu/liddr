defmodule Liddr.Rides.SharedRides.StopOptimizerTest do
  use ExUnit.Case, async: true

  alias Liddr.Rides.SharedRides.StopOptimizer

  test "orders stops by nearest feasible while keeping pickup before dropoff" do
    start_point = {-1.3000, 36.8000}

    stops = [
      stop(1, "pickup", -1.2999, 36.8000),
      stop(1, "dropoff", -1.2400, 36.8000),
      stop(2, "pickup", -1.2800, 36.8000),
      stop(2, "dropoff", -1.2790, 36.8000)
    ]

    ordered = StopOptimizer.order_stops(start_point, stops, MapSet.new())

    assert Enum.map(ordered, &{&1.member_id, &1.stop_type}) == [
             {1, "pickup"},
             {2, "pickup"},
             {2, "dropoff"},
             {1, "dropoff"}
           ]
  end

  test "allows dropoff first for already picked-up member" do
    start_point = {-1.3000, 36.8000}

    stops = [
      stop(10, "dropoff", -1.2999, 36.8000),
      stop(20, "pickup", -1.2900, 36.8000),
      stop(20, "dropoff", -1.2890, 36.8000)
    ]

    ordered = StopOptimizer.order_stops(start_point, stops, MapSet.new([10]))

    assert Enum.map(ordered, &{&1.member_id, &1.stop_type}) == [
             {10, "dropoff"},
             {20, "pickup"},
             {20, "dropoff"}
           ]
  end

  defp stop(member_id, stop_type, lat, lng) do
    %{
      stop_key: "#{member_id}:#{stop_type}",
      member_id: member_id,
      stop_type: stop_type,
      lat: lat,
      lng: lng,
      requested_at: ~U[2026-03-04 00:00:00.000000Z]
    }
  end
end
