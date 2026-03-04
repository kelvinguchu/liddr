defmodule Liddr.Rides.SharedRides.StopPlanner do
  @moduledoc false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRideStop
  alias Liddr.Rides.SharedRides.StopEta
  alias Liddr.Rides.SharedRides.StopOptimizer

  @terminal_statuses ~w(cancelled no_show dropped_off)
  @pickup_statuses ~w(requested assigned pickup_pending)
  @dropoff_statuses ~w(requested assigned pickup_pending picked_up dropoff_pending)

  def plan_entries(%Ride{} = ride, members) when is_list(members) do
    build_plan(ride, members)
  end

  def replan_for_ride!(ride_id, now) do
    ride =
      Repo.one(
        from r in Ride,
          where: r.id == ^ride_id,
          lock: "FOR UPDATE",
          limit: 1
      )

    group =
      Repo.one(
        from g in SharedRideGroup,
          where: g.ride_id == ^ride_id,
          lock: "FOR UPDATE",
          limit: 1
      )

    if is_nil(ride) or is_nil(group) do
      :ok
    else
      members =
        Repo.all(
          from m in SharedRideMember,
            where: m.ride_id == ^ride_id and m.status not in ^@terminal_statuses,
            order_by: [asc: m.requested_at, asc: m.id]
        )

      _ = Repo.delete_all(from s in SharedRideStop, where: s.ride_id == ^ride_id)

      planned =
        ride
        |> plan_entries(members)
        |> StopEta.annotate(ride, now)

      _ = insert_plan(group.id, ride.id, planned, now)
      :ok
    end
  end

  def refresh_pending_eta_for_ride!(ride_id, start_point, now) do
    ride =
      Repo.one(
        from r in Ride,
          where: r.id == ^ride_id,
          lock: "FOR UPDATE",
          limit: 1
      )

    if is_nil(ride) do
      :ok
    else
      pending_stops =
        Repo.all(
          from s in SharedRideStop,
            where: s.ride_id == ^ride_id and s.status == "pending",
            order_by: [asc: s.sequence, asc: s.id],
            lock: "FOR UPDATE"
        )

      origin = normalize_start_point(start_point, ride)

      pending_stops
      |> Enum.map(&map_pending_stop/1)
      |> StopEta.annotate_from(origin, now)
      |> Enum.each(fn annotated ->
        _ =
          Repo.update_all(
            from(s in SharedRideStop, where: s.id == ^annotated.id),
            set: [
              eta_at: annotated.eta_at,
              metadata: merge_eta_metadata(annotated.base_metadata, annotated.metadata),
              updated_at: now
            ]
          )
      end)

      :ok
    end
  end

  defp build_plan(ride, members) do
    {stops, pre_picked_member_ids} = stop_candidates(ride, members)

    start_point = {
      Geo.to_float(ride.pickup_lat),
      Geo.to_float(ride.pickup_lng)
    }

    StopOptimizer.order_stops(start_point, stops, pre_picked_member_ids)
    |> Enum.map(fn stop ->
      %{
        member: stop.member,
        stop_type: stop.stop_type,
        lat: stop.lat,
        lng: stop.lng
      }
    end)
  end

  defp stop_candidates(ride, members) do
    pickups =
      members
      |> Enum.filter(&(&1.status in @pickup_statuses))
      |> Enum.map(fn member -> stop_entry(member, :pickup, ride) end)

    dropoffs =
      members
      |> Enum.filter(&(&1.status in @dropoff_statuses))
      |> Enum.map(fn member -> stop_entry(member, :dropoff, ride) end)

    pre_picked_member_ids =
      members
      |> Enum.filter(&(&1.status in ~w(picked_up dropoff_pending)))
      |> Enum.map(& &1.id)
      |> MapSet.new()

    {pickups ++ dropoffs, pre_picked_member_ids}
  end

  defp stop_entry(member, :pickup, ride) do
    {lat, lng} = pickup_coordinates(member, ride)

    %{
      stop_key: "#{member.id}:pickup",
      member: member,
      member_id: member.id,
      stop_type: "pickup",
      lat: lat,
      lng: lng,
      requested_at: member.requested_at
    }
  end

  defp stop_entry(member, :dropoff, ride) do
    {lat, lng} = dropoff_coordinates(member, ride)

    %{
      stop_key: "#{member.id}:dropoff",
      member: member,
      member_id: member.id,
      stop_type: "dropoff",
      lat: lat,
      lng: lng,
      requested_at: member.requested_at
    }
  end

  defp pickup_coordinates(member, ride) do
    metadata = normalize_metadata(member.metadata)

    lat =
      metadata["pickup_lat"] ||
        (ride && ride.pickup_lat) ||
        0.0

    lng =
      metadata["pickup_lng"] ||
        (ride && ride.pickup_lng) ||
        0.0

    {to_float(lat), to_float(lng)}
  end

  defp dropoff_coordinates(member, ride) do
    metadata = normalize_metadata(member.metadata)

    lat =
      metadata["dropoff_lat"] ||
        (ride && ride.dropoff_lat) ||
        0.0

    lng =
      metadata["dropoff_lng"] ||
        (ride && ride.dropoff_lng) ||
        0.0

    {to_float(lat), to_float(lng)}
  end

  defp insert_plan(group_id, ride_id, planned, now) do
    planned
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, sequence} ->
      %{
        group_id: group_id,
        ride_id: ride_id,
        member_id: entry.member.id,
        stop_type: entry.stop_type,
        status: "pending",
        sequence: sequence,
        lat: to_decimal(entry.lat),
        lng: to_decimal(entry.lng),
        eta_at: entry.eta_at,
        metadata: %{"planned_at" => now, "eta" => entry.metadata},
        inserted_at: now,
        updated_at: now
      }
    end)
    |> case do
      [] -> {0, []}
      rows -> Repo.insert_all(SharedRideStop, rows)
    end
  end

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_start_point({lat, lng}, _ride), do: {to_float(lat), to_float(lng)}

  defp normalize_start_point(_start_point, ride) do
    {to_float(ride.pickup_lat), to_float(ride.pickup_lng)}
  end

  defp map_pending_stop(stop) do
    %{
      id: stop.id,
      lat: stop.lat,
      lng: stop.lng,
      metadata: %{},
      base_metadata: normalize_metadata(stop.metadata)
    }
  end

  defp merge_eta_metadata(metadata, eta_metadata) do
    metadata
    |> Map.delete("eta")
    |> Map.put("eta", eta_metadata)
  end

  defp to_float(%D{} = value), do: D.to_float(value)
  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> 0.0
    end
  end

  defp to_float(_value), do: 0.0
  defp to_decimal(value), do: D.from_float(value) |> D.round(7)
end
