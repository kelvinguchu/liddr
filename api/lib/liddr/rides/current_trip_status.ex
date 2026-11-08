defmodule Liddr.Rides.CurrentTripStatus do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.DriverTracking
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.SharedRides.Access
  alias LiddrWeb.RideSerializer

  @status_event_types ~w(
    ride_requested
    ride_accepted
    driver_arriving
    driver_arrived
    trip_started
    ride_completed
    ride_cancelled
    trip_cancelled
    driver_delayed
    driver_offline_detected
    reassigning_driver
    ride_reassigned
    new_driver_found
  )

  @terminal_statuses ~w(completed cancelled)

  def fetch_for_user(user_id, ride_id) do
    with parsed_ride_id when not is_nil(parsed_ride_id) <- parse_positive_integer(ride_id),
         %Ride{} = ride <- fetch_accessible_ride(user_id, parsed_ride_id) do
      latest_status_event = latest_status_event(ride.id)
      latest_status_at = latest_status_timestamp(latest_status_event)

      {:ok,
       %{
         ride: ride,
         current_trip_status: %{
           current_stage: current_stage(ride.status),
           recommended_action: recommended_action(ride.status, latest_status_event),
           is_terminal: ride.status in @terminal_statuses,
           latest_status_event:
             if(latest_status_event, do: RideSerializer.event_payload(latest_status_event)),
           status_updated_at: status_updated_at(ride.updated_at, latest_status_at),
           reassign_context: reassign_context(ride.metadata),
           driver_location: DriverTracking.latest_for_user(ride, user_id)
         }
       }}
    else
      _ -> {:error, :ride_not_accessible}
    end
  end

  defp fetch_accessible_ride(user_id, ride_id) do
    Ride
    |> Access.scope_for_user(user_id)
    |> where([r], r.id == ^ride_id)
    |> limit(1)
    |> Repo.one()
  end

  defp latest_status_event(ride_id) do
    Repo.one(
      from e in RideEvent,
        where: e.ride_id == ^ride_id and e.event_type in ^@status_event_types,
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: 1
    )
  end

  defp current_stage("requested"), do: "searching_driver"
  defp current_stage("offering"), do: "searching_driver"
  defp current_stage("accepted"), do: "driver_assigned"
  defp current_stage("driver_arriving"), do: "driver_arriving"
  defp current_stage("arrived"), do: "driver_arrived"
  defp current_stage("in_progress"), do: "in_trip"
  defp current_stage("completed"), do: "completed"
  defp current_stage("cancelled"), do: "cancelled"
  defp current_stage(_status), do: "unknown"

  defp recommended_action(status, latest_status_event) do
    case {status, latest_status_type(latest_status_event)} do
      {"offering", "reassigning_driver"} -> "wait_for_new_driver"
      {"offering", "driver_offline_detected"} -> "wait_for_new_driver"
      {"offering", "driver_delayed"} -> "wait_or_reassign"
      {"accepted", "driver_delayed"} -> "wait_or_reassign"
      {"accepted", "driver_offline_detected"} -> "reassign"
      {"driver_arriving", "driver_delayed"} -> "wait_or_reassign"
      {"driver_arriving", "driver_offline_detected"} -> "reassign"
      {"arrived", _} -> "meet_driver"
      {"in_progress", _} -> "continue_trip"
      {"completed", _} -> "rate_trip"
      {"cancelled", _} -> "request_new_ride"
      {"offering", _} -> "wait_for_driver"
      {"requested", _} -> "wait_for_driver"
      {"accepted", _} -> "prepare_for_pickup"
      {"driver_arriving", _} -> "prepare_for_pickup"
      _ -> "check_trip"
    end
  end

  defp reassign_context(%{} = metadata) do
    %{
      reassign_count: parse_non_negative_integer(Map.get(metadata, "reassign_count"), 0),
      last_reassign_at: Map.get(metadata, "last_reassign_at"),
      last_reassign_driver_id: Map.get(metadata, "last_reassign_driver_id"),
      last_reassign_reason_code: Map.get(metadata, "last_reassign_reason_code")
    }
  end

  defp reassign_context(_metadata) do
    %{
      reassign_count: 0,
      last_reassign_at: nil,
      last_reassign_driver_id: nil,
      last_reassign_reason_code: nil
    }
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp parse_non_negative_integer(_value, default), do: default

  defp latest_status_timestamp(%RideEvent{occurred_at: occurred_at}), do: occurred_at
  defp latest_status_timestamp(_event), do: nil

  defp latest_status_type(%RideEvent{event_type: event_type}), do: event_type
  defp latest_status_type(_event), do: nil

  defp status_updated_at(%DateTime{} = ride_updated_at, nil), do: ride_updated_at
  defp status_updated_at(nil, %DateTime{} = latest_status_at), do: latest_status_at

  defp status_updated_at(%DateTime{} = ride_updated_at, %DateTime{} = latest_status_at) do
    case DateTime.compare(ride_updated_at, latest_status_at) do
      :lt -> latest_status_at
      _ -> ride_updated_at
    end
  end
end
