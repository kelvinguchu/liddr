defmodule Liddr.Rides.Execution.Cancellation do
  alias Liddr.Location
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Geofence
  alias Liddr.Rides.Execution.GeoPolicy
  alias Liddr.Rides.Integrity.Classifier
  alias Liddr.Rides.Integrity.Enforcement
  alias Liddr.Rides.Notifications
  alias Liddr.Repo
  alias Liddr.Rides.Dispatcher
  alias Liddr.Rides.Execution.Shared
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

  def rider_cancel_ride(rider_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <- resolve_cancel_reason(attrs, @rider_cancel_reason_codes) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_rider_owns_ride!(ride, rider_user_id)

          cond do
            ride.status == "cancelled" ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: reason}

            ride.status in @rider_cancellable_statuses ->
              integrity = Classifier.classify_rider_cancel(ride, reason, now)
              cancelled_ride = cancel_ride!(ride, "rider", reason, now, integrity)
              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              _ =
                record_cancel_event(cancelled_ride.id, now, rider_user_id, %{
                  "cancelled_by" => "rider",
                  "reason_code" => reason
                })

              _ =
                record_integrity_event(
                  cancelled_ride.id,
                  now,
                  rider_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, rider_user_id, reason, now)

              _ =
                record_notification_event(cancelled_ride.id, now, rider_user_id, %{
                  "event_type" => "ride_cancelled",
                  "recipient_count" => length(recipient_user_ids)
                })

              unlocked_driver_id = Shared.maybe_unlock_assigned_driver!(cancelled_ride, now)

              %{
                ride: cancelled_ride,
                transition?: true,
                unlocked_driver_id: unlocked_driver_id,
                reason: reason,
                integrity: integrity,
                enforcement: enforcement,
                notification_recipient_user_ids: recipient_user_ids
              }

            true ->
              Repo.rollback(:ride_not_cancellable)
          end
        end)
        |> Shared.unwrap_transaction_result()

      handle_cancel_result(result)
    end
  end

  def driver_cancel_ride(driver_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <- resolve_cancel_reason(attrs, @driver_cancel_reason_codes) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_driver_owns_ride!(ride, driver_user_id)
          driver = Shared.fetch_driver_for_update!(driver_user_id)
          Shared.ensure_driver_locked_to_ride!(driver, ride.id)

          cond do
            ride.status == "cancelled" ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: reason}

            ride.status in @driver_cancellable_statuses ->
              if ride.status == "in_progress" and
                   reason not in @driver_in_progress_cancel_reason_codes do
                Repo.rollback(:driver_cancel_requires_emergency_reason)
              end

              integrity = Classifier.classify_driver_cancel(ride, reason, now)
              cancelled_ride = cancel_ride!(ride, "driver", reason, now, integrity)
              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              _ =
                record_cancel_event(cancelled_ride.id, now, driver_user_id, %{
                  "cancelled_by" => "driver",
                  "reason_code" => reason
                })

              _ =
                record_integrity_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, driver_user_id, reason, now)

              _ =
                record_notification_event(cancelled_ride.id, now, driver_user_id, %{
                  "event_type" => "ride_cancelled",
                  "recipient_count" => length(recipient_user_ids)
                })

              _ =
                Shared.release_driver_after_cancellation!(driver, now, %{
                  keep_unavailable: driver_suspension_applied?(enforcement)
                })

              %{
                ride: cancelled_ride,
                transition?: true,
                unlocked_driver_id: driver_user_id,
                reason: reason,
                integrity: integrity,
                enforcement: enforcement,
                notification_recipient_user_ids: recipient_user_ids
              }

            true ->
              Repo.rollback(:ride_not_cancellable)
          end
        end)
        |> Shared.unwrap_transaction_result()

      handle_cancel_result(result)
    end
  end

  def mark_rider_no_show(driver_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <- resolve_no_show_reason(attrs) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_driver_owns_ride!(ride, driver_user_id)
          driver = Shared.fetch_driver_for_update!(driver_user_id)
          Shared.ensure_driver_locked_to_ride!(driver, ride.id)

          cond do
            ride.status == "cancelled" and Shared.cancellation_reason(ride) == "rider_no_show" ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: "rider_no_show"}

            ride.status == "arrived" ->
              geofence = Geofence.ensure_arrival!(ride, driver.user_id, now)
              wait_elapsed_seconds = ensure_no_show_wait_elapsed!(ride, now)

              no_show_signals = %{
                "arrived_elapsed_seconds" => wait_elapsed_seconds,
                "required_wait_seconds" => GeoPolicy.no_show_wait_seconds(),
                "distance_to_pickup_m" => geofence.distance_m
              }

              integrity = Classifier.classify_rider_no_show(ride, now, no_show_signals)
              cancelled_ride = cancel_ride!(ride, "driver", reason, now, integrity)
              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              _ =
                record_cancel_event(cancelled_ride.id, now, driver_user_id, %{
                  "cancelled_by" => "driver",
                  "reason_code" => reason,
                  "no_show" => true,
                  "signals" => no_show_signals
                })

              _ =
                record_integrity_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, driver_user_id, reason, now)

              _ =
                record_notification_event(cancelled_ride.id, now, driver_user_id, %{
                  "event_type" => "ride_cancelled",
                  "recipient_count" => length(recipient_user_ids),
                  "no_show" => true,
                  "signals" => no_show_signals
                })

              _ =
                Shared.release_driver_after_cancellation!(driver, now, %{
                  keep_unavailable: driver_suspension_applied?(enforcement)
                })

              %{
                ride: cancelled_ride,
                transition?: true,
                unlocked_driver_id: driver_user_id,
                reason: reason,
                integrity: integrity,
                enforcement: enforcement,
                notification_recipient_user_ids: recipient_user_ids
              }

            true ->
              Repo.rollback(:ride_not_no_show_eligible)
          end
        end)
        |> Shared.unwrap_transaction_result()

      handle_cancel_result(result)
    end
  end

  defp handle_cancel_result(
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

  defp handle_cancel_result({:ok, %{ride: ride}}), do: {:ok, ride}
  defp handle_cancel_result(error), do: error

  defp cancel_ride!(ride, cancelled_by, reason, now, integrity) do
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

  defp actor_user_id("rider", ride), do: ride.rider_id
  defp actor_user_id("driver", ride), do: ride.driver_id
  defp actor_user_id(_other, _ride), do: nil

  defp record_cancel_event(ride_id, occurred_at, actor_user_id, payload) do
    Events.record_event(ride_id, "ride_cancelled", occurred_at,
      actor_user_id: actor_user_id,
      payload: payload
    )
    |> Shared.unwrap_or_rollback()
  end

  defp record_notification_event(ride_id, occurred_at, actor_user_id, payload) do
    Events.record_event(ride_id, "ride_notification_queued", occurred_at,
      actor_user_id: actor_user_id,
      payload: payload
    )
    |> Shared.unwrap_or_rollback()
  end

  defp record_integrity_event(ride_id, occurred_at, actor_user_id, integrity, enforcement) do
    Events.record_event(ride_id, "ride_integrity_evaluated", occurred_at,
      actor_user_id: actor_user_id,
      payload: %{"integrity" => integrity, "enforcement" => enforcement}
    )
    |> Shared.unwrap_or_rollback()
  end

  defp resolve_cancel_reason(attrs, allowed_codes) do
    case Shared.extract_cancel_reason(attrs) do
      {:ok, reason_code} ->
        if reason_code in allowed_codes,
          do: {:ok, reason_code},
          else: {:error, :invalid_cancel_reason}

      {:error, :missing} ->
        {:error, :missing_cancel_reason}
    end
  end

  defp resolve_no_show_reason(attrs) do
    case Shared.extract_cancel_reason(attrs) do
      {:ok, @rider_no_show_reason_code} -> {:ok, @rider_no_show_reason_code}
      {:ok, _reason_code} -> {:error, :invalid_cancel_reason}
      {:error, :missing} -> {:ok, @rider_no_show_reason_code}
    end
  end

  defp ensure_no_show_wait_elapsed!(ride, now) do
    elapsed_seconds =
      case ride.arrived_at do
        %DateTime{} = arrived_at -> max(DateTime.diff(now, arrived_at, :second), 0)
        _ -> 0
      end

    if elapsed_seconds < GeoPolicy.no_show_wait_seconds(),
      do: Repo.rollback(:ride_no_show_wait_not_elapsed),
      else: elapsed_seconds
  end

  defp driver_suspension_applied?(%{"action" => %{"type" => "driver_temporary_suspension"}}),
    do: true

  defp driver_suspension_applied?(_enforcement), do: false
end
