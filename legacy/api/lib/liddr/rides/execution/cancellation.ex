defmodule Liddr.Rides.Execution.Cancellation do
  alias Liddr.Rides.Execution.CancellationSupport
  alias Liddr.Rides.Execution.Geofence
  alias Liddr.Rides.Execution.GeoPolicy
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Integrity.Classifier
  alias Liddr.Rides.Integrity.Enforcement
  alias Liddr.Rides.Notifications
  alias Liddr.Repo

  def rider_cancel_ride(rider_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <-
           CancellationSupport.resolve_cancel_reason(
             attrs,
             CancellationSupport.rider_cancel_reason_codes()
           ) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_rider_owns_ride!(ride, rider_user_id)

          cond do
            ride.status == "cancelled" ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: reason}

            ride.status in CancellationSupport.rider_cancellable_statuses() ->
              integrity = Classifier.classify_rider_cancel(ride, reason, now)

              cancelled_ride =
                CancellationSupport.cancel_ride!(ride, "rider", reason, now, integrity)

              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              cancelled_ride =
                CancellationSupport.persist_cancellation_outcome!(
                  cancelled_ride,
                  integrity,
                  enforcement
                )

              _ =
                CancellationSupport.record_cancel_event(
                  cancelled_ride.id,
                  now,
                  rider_user_id,
                  %{"cancelled_by" => "rider", "reason_code" => reason}
                )

              _ =
                CancellationSupport.record_integrity_event(
                  cancelled_ride.id,
                  now,
                  rider_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, rider_user_id, reason, now)

              _ =
                CancellationSupport.record_notification_event(
                  cancelled_ride.id,
                  now,
                  rider_user_id,
                  %{
                    "event_type" => "ride_cancelled",
                    "recipient_count" => length(recipient_user_ids)
                  }
                )

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

      CancellationSupport.handle_cancel_result(result)
    end
  end

  def driver_cancel_ride(driver_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <-
           CancellationSupport.resolve_cancel_reason(
             attrs,
             CancellationSupport.driver_cancel_reason_codes()
           ) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_driver_owns_ride!(ride, driver_user_id)
          driver = Shared.fetch_driver_for_update!(driver_user_id)
          Shared.ensure_driver_locked_to_ride!(driver, ride.id)

          cond do
            ride.status == "cancelled" ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: reason}

            ride.status in CancellationSupport.driver_cancellable_statuses() ->
              if ride.status == "in_progress" and
                   reason not in CancellationSupport.driver_in_progress_cancel_reason_codes() do
                Repo.rollback(:driver_cancel_requires_emergency_reason)
              end

              integrity = Classifier.classify_driver_cancel(ride, reason, now)

              cancelled_ride =
                CancellationSupport.cancel_ride!(ride, "driver", reason, now, integrity)

              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              cancelled_ride =
                CancellationSupport.persist_cancellation_outcome!(
                  cancelled_ride,
                  integrity,
                  enforcement
                )

              _ =
                CancellationSupport.record_cancel_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  %{"cancelled_by" => "driver", "reason_code" => reason}
                )

              _ =
                CancellationSupport.record_integrity_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, driver_user_id, reason, now)

              _ =
                CancellationSupport.record_notification_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  %{
                    "event_type" => "ride_cancelled",
                    "recipient_count" => length(recipient_user_ids)
                  }
                )

              _ =
                Shared.release_driver_after_cancellation!(driver, now, %{
                  keep_unavailable: CancellationSupport.driver_suspension_applied?(enforcement)
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

      CancellationSupport.handle_cancel_result(result)
    end
  end

  def mark_rider_no_show(driver_user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, reason} <- CancellationSupport.resolve_no_show_reason(attrs) do
      result =
        Repo.transaction(fn ->
          ride = Shared.fetch_ride_for_update!(ride_id)
          Shared.ensure_driver_owns_ride!(ride, driver_user_id)
          driver = Shared.fetch_driver_for_update!(driver_user_id)
          Shared.ensure_driver_locked_to_ride!(driver, ride.id)

          cond do
            ride.status == "cancelled" and
                Shared.cancellation_reason(ride) ==
                  CancellationSupport.rider_no_show_reason_code() ->
              %{ride: ride, transition?: false, unlocked_driver_id: nil, reason: reason}

            ride.status == "arrived" ->
              geofence = Geofence.ensure_arrival!(ride, driver.user_id, now)
              wait_elapsed_seconds = CancellationSupport.ensure_no_show_wait_elapsed!(ride, now)

              no_show_signals = %{
                "arrived_elapsed_seconds" => wait_elapsed_seconds,
                "required_wait_seconds" => GeoPolicy.no_show_wait_seconds(),
                "distance_to_pickup_m" => geofence.distance_m
              }

              integrity = Classifier.classify_rider_no_show(ride, now, no_show_signals)

              cancelled_ride =
                CancellationSupport.cancel_ride!(ride, "driver", reason, now, integrity)

              enforcement = Enforcement.apply_after_cancellation!(cancelled_ride, integrity, now)

              cancelled_ride =
                CancellationSupport.persist_cancellation_outcome!(
                  cancelled_ride,
                  integrity,
                  enforcement
                )

              _ =
                CancellationSupport.record_cancel_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  %{
                    "cancelled_by" => "driver",
                    "reason_code" => reason,
                    "no_show" => true,
                    "signals" => no_show_signals
                  }
                )

              _ =
                CancellationSupport.record_integrity_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  integrity,
                  enforcement
                )

              recipient_user_ids =
                Notifications.queue_ride_cancelled!(cancelled_ride, driver_user_id, reason, now)

              _ =
                CancellationSupport.record_notification_event(
                  cancelled_ride.id,
                  now,
                  driver_user_id,
                  %{
                    "event_type" => "ride_cancelled",
                    "recipient_count" => length(recipient_user_ids),
                    "no_show" => true,
                    "signals" => no_show_signals
                  }
                )

              _ =
                Shared.release_driver_after_cancellation!(driver, now, %{
                  keep_unavailable: CancellationSupport.driver_suspension_applied?(enforcement)
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

      CancellationSupport.handle_cancel_result(result)
    end
  end
end
