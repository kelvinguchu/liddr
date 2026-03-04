defmodule LiddrWeb.SharedRideSerializer do
  alias LiddrWeb.RideSerializer

  def context_payload(%{ride: ride, group: group, members: members, stops: stops}) do
    next_stop =
      stops
      |> Enum.find(&(&1.status == "pending"))
      |> maybe_stop_payload()

    %{
      ride: RideSerializer.ride_payload(ride),
      group: group_payload(group),
      members: Enum.map(members, &member_payload/1),
      stops: Enum.map(stops, &stop_payload/1),
      next_stop: next_stop
    }
  end

  defp group_payload(nil), do: nil

  defp group_payload(group) do
    %{
      id: group.id,
      ride_id: group.ride_id,
      max_members: group.max_members,
      metadata: group.metadata,
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end

  defp member_payload(member) do
    %{
      id: member.id,
      group_id: member.group_id,
      ride_id: member.ride_id,
      rider_user_id: member.rider_user_id,
      status: member.status,
      requested_at: member.requested_at,
      picked_up_at: member.picked_up_at,
      dropped_off_at: member.dropped_off_at,
      cancelled_at: member.cancelled_at,
      no_show_marked_at: member.no_show_marked_at,
      cancellation_reason_code: member.cancellation_reason_code,
      cancelled_by_user_id: member.cancelled_by_user_id,
      fare_kes: member.fare_kes,
      metadata: member.metadata,
      inserted_at: member.inserted_at,
      updated_at: member.updated_at
    }
  end

  defp stop_payload(stop) do
    %{
      id: stop.id,
      group_id: stop.group_id,
      ride_id: stop.ride_id,
      member_id: stop.member_id,
      stop_type: stop.stop_type,
      status: stop.status,
      sequence: stop.sequence,
      lat: stop.lat,
      lng: stop.lng,
      eta_at: stop.eta_at,
      completed_at: stop.completed_at,
      metadata: stop.metadata,
      inserted_at: stop.inserted_at,
      updated_at: stop.updated_at
    }
  end

  defp maybe_stop_payload(nil), do: nil
  defp maybe_stop_payload(stop), do: stop_payload(stop)
end
