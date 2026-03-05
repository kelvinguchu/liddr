defmodule Liddr.Rides.SharedRides.DetourGuard do
  @moduledoc false

  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRides.StopPlanner

  @defaults %{
    max_extra_detour_m: 2_000.0,
    max_extra_detour_ratio: 0.6
  }

  def ensure_join_viable(%Ride{} = ride, current_members, joining_member)
      when is_list(current_members) and is_map(joining_member) do
    policy = policy()

    current_distance_m =
      ride
      |> StopPlanner.plan_entries(current_members)
      |> plan_distance_m(ride)

    projected_distance_m =
      ride
      |> StopPlanner.plan_entries([joining_member | current_members])
      |> plan_distance_m(ride)

    extra_detour_m = max(projected_distance_m - current_distance_m, 0.0)

    detour_ratio =
      if current_distance_m > 1.0 do
        extra_detour_m / current_distance_m
      else
        0.0
      end

    if extra_detour_m <= policy.max_extra_detour_m and
         detour_ratio <= policy.max_extra_detour_ratio do
      :ok
    else
      {:error, :shared_join_excessive_detour}
    end
  end

  defp plan_distance_m([], _ride), do: 0.0

  defp plan_distance_m(entries, ride) do
    points = [{Geo.to_float(ride.pickup_lat), Geo.to_float(ride.pickup_lng)} | to_points(entries)]

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [{from_lat, from_lng}, {to_lat, to_lng}], acc ->
      acc + Geo.haversine_distance_m(from_lat, from_lng, to_lat, to_lng)
    end)
  end

  defp to_points(entries) do
    Enum.map(entries, fn entry ->
      {Geo.to_float(entry.lat), Geo.to_float(entry.lng)}
    end)
  end

  defp policy do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      max_extra_detour_m: get_number(config, :max_extra_detour_m, @defaults.max_extra_detour_m),
      max_extra_detour_ratio:
        get_number(config, :max_extra_detour_ratio, @defaults.max_extra_detour_ratio)
    }
  end

  defp get_number(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _ -> default
    end
  end
end
