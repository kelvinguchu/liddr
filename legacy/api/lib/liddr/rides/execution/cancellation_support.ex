defmodule Liddr.Rides.Execution.CancellationSupport do
  alias Liddr.Location
  alias Liddr.Repo
  alias Liddr.Rides.CancellationOutcome
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.GeoPolicy
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.Realtime

  @rider_cancellable_statuses ~w(requested offering accepted driver_arriving arrived)
  @driver_cancellable_statuses ~w(accepted driver_arriving arrived in_progress)

  @rider_cancel_reason_codes ~w(
    rider_changed_mind
    driver_too_far
    driver_not_moving
    cannot_contact_driver
    safety_concern
    emergency
  )

  @driver_cancel_reason_codes ~w(
    vehicle_issue
    cannot_contact_rider
    safety_concern
    emergency
  )

  @driver_in_progress_cancel_reason_codes ~w(vehicle_issue safety_concern emergency)
  @rider_no_show_reason_code "rider_no_show"

  def rider_cancellable_statuses, do: @rider_cancellable_statuses
  def driver_cancellable_statuses, do: @driver_cancellable_statuses
  def rider_cancel_reason_codes, do: @rider_cancel_reason_codes
  def driver_cancel_reason_codes, do: @driver_cancel_reason_codes
  def driver_in_progress_cancel_reason_codes, do: @driver_in_progress_cancel_reason_codes
  def rider_no_show_reason_code, do: @rider_no_show_reason_code

  def resolve_cancel_reason(attrs, allowed_codes) do
    case Shared.extract_cancel_reason(attrs) do
      {:ok, reason_code} ->
        if reason_code in allowed_codes,
          do: {:ok, reason_code},
          else: {:error, :invalid_cancel_reason}

      {:error, :missing} ->
        {:error, :missing_cancel_reason}
    end
  end

  def resolve_no_show_reason(attrs) do
    case Shared.extract_cancel_reason(attrs) do
      {:ok, @rider_no_show_reason_code} -> {:ok, @rider_no_show_reason_code}
      {:ok, _reason_code} -> {:error, :invalid_cancel_reason}
      {:error, :missing} -> {:ok, @rider_no_show_reason_code}
    end
  end

  def cancel_ride!(ride, cancelled_by, reason, now, integrity) do
    metadata =
      ride.metadata
      |> Shared.normalize_metadata()
      |> Map.put("cancelled_by", cancelled_by)
      |> Map.put("cancel_reason_code", reason)
      |> Map.put("integrity", integrity)

    Shared.update_ride!(ride, %{
      "status" => "cancelled",
      "cancelled_at" => now,
      "cancellation_reason_code" => reason,
      "cancelled_by_user_id" => actor_user_id(cancelled_by, ride),
      "no_show_marked_at" => if(reason == @rider_no_show_reason_code, do: now, else: nil),
      "metadata" => metadata
    })
  end

  def persist_cancellation_outcome!(ride, integrity, enforcement) do
    metadata = CancellationOutcome.enrich_metadata(ride.metadata, integrity, enforcement)
    Shared.update_ride!(ride, %{"metadata" => metadata})
  end

  def record_cancel_event(ride_id, occurred_at, actor_user_id, payload) do
    Events.record_event(ride_id, "ride_cancelled", occurred_at,
      actor_user_id: actor_user_id,
      payload: payload
    )
    |> Shared.unwrap_or_rollback()
  end

  def record_notification_event(ride_id, occurred_at, actor_user_id, payload) do
    Events.record_event(ride_id, "ride_notification_queued", occurred_at,
      actor_user_id: actor_user_id,
      payload: payload
    )
    |> Shared.unwrap_or_rollback()
  end

  def record_integrity_event(ride_id, occurred_at, actor_user_id, integrity, enforcement) do
    Events.record_event(ride_id, "ride_integrity_evaluated", occurred_at,
      actor_user_id: actor_user_id,
      payload: %{"integrity" => integrity, "enforcement" => enforcement}
    )
    |> Shared.unwrap_or_rollback()
  end

  def handle_cancel_result(
        {:ok,
         %{
           ride: ride,
           transition?: true,
           unlocked_driver_id: driver_id,
           reason: reason,
           notification_recipient_user_ids: notification_recipient_user_ids
         }}
      ) do
    broadcasted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Realtime.broadcast_trip_cancelled(ride, reason)

    _ =
      Notifications.mark_socket_sent(
        ride.id,
        "ride_cancelled",
        notification_recipient_user_ids,
        broadcasted_at
      )

    if is_integer(driver_id) do
      _ = Location.sync_driver_supply(driver_id)
      Realtime.broadcast_driver_unlocked(driver_id, ride.id)
    end

    Dispatcher.stop(ride.id)
    {:ok, ride}
  end

  def handle_cancel_result({:ok, %{ride: ride}}), do: {:ok, ride}
  def handle_cancel_result(error), do: error

  def ensure_no_show_wait_elapsed!(ride, now) do
    elapsed_seconds =
      case ride.arrived_at do
        %DateTime{} = arrived_at -> max(DateTime.diff(now, arrived_at, :second), 0)
        _ -> 0
      end

    if elapsed_seconds < GeoPolicy.no_show_wait_seconds(),
      do: Repo.rollback(:ride_no_show_wait_not_elapsed),
      else: elapsed_seconds
  end

  def driver_suspension_applied?(%{"action" => %{"type" => "driver_temporary_suspension"}}),
    do: true

  def driver_suspension_applied?(_enforcement), do: false

  defp actor_user_id("rider", ride), do: ride.rider_id
  defp actor_user_id("driver", ride), do: ride.driver_id
  defp actor_user_id(_other, _ride), do: nil
end
