defmodule Liddr.Rides do
  alias Liddr.Rides.Execution
  alias Liddr.Rides.History
  alias Liddr.Rides.Integrity
  alias Liddr.Rides.Lifecycle
  alias Liddr.Rides.DestinationChanges
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.NotificationRetry
  alias Liddr.Rides.Timeline
  alias Liddr.Rides.Requests
  alias Liddr.Rides.Quotes
  alias Liddr.Rides.PickupWatchdog
  alias Liddr.Rides.PickupWatchdogSummary
  alias Liddr.Rides.Trips

  defdelegate request_ride(rider_user_id, attrs \\ %{}), to: Requests
  defdelegate create_quote(rider_user_id, attrs \\ %{}), to: Quotes
  defdelegate list_driver_offers(driver_user_id, attrs \\ %{}), to: Lifecycle
  defdelegate accept_offer(driver_user_id, offer_id), to: Lifecycle
  defdelegate reject_offer(driver_user_id, offer_id), to: Lifecycle
  defdelegate mark_driver_arriving(driver_user_id, ride_id), to: Execution
  defdelegate mark_driver_arrived(driver_user_id, ride_id), to: Execution
  defdelegate start_ride(driver_user_id, ride_id), to: Execution
  defdelegate pickup_health(rider_user_id, ride_id), to: Execution
  defdelegate request_reassign(rider_user_id, ride_id, attrs \\ %{}), to: Execution
  defdelegate rider_cancel_ride(rider_user_id, ride_id, attrs \\ %{}), to: Execution
  defdelegate driver_cancel_ride(driver_user_id, ride_id, attrs \\ %{}), to: Execution
  defdelegate mark_rider_no_show(driver_user_id, ride_id, attrs \\ %{}), to: Execution

  defdelegate request_destination_change(rider_user_id, ride_id, attrs \\ %{}),
    to: DestinationChanges,
    as: :request_change

  defdelegate accept_destination_change(driver_user_id, ride_id, destination_change_id),
    to: DestinationChanges,
    as: :accept_change

  defdelegate reject_destination_change(
                driver_user_id,
                ride_id,
                destination_change_id,
                attrs \\ %{}
              ), to: DestinationChanges, as: :reject_change

  defdelegate complete_ride(driver_user_id, ride_id, attrs \\ %{}), to: Trips
  defdelegate get_ride_for_user(user_id, ride_id), to: Timeline
  defdelegate list_events_for_user(user_id, ride_id, attrs \\ %{}), to: Timeline
  defdelegate list_incidents_for_user(user_id, ride_id, attrs \\ %{}), to: Timeline
  defdelegate rider_history(rider_user_id, attrs \\ %{}), to: History
  defdelegate driver_history(driver_user_id, attrs \\ %{}), to: History

  defdelegate ops_lookup_user_integrity(user_id, attrs \\ %{}),
    to: Integrity,
    as: :ops_lookup_user

  defdelegate expire_due_rider_prepay_modes(attrs \\ %{}), to: Integrity
  defdelegate integrity_self_view(user_id, roles, attrs \\ %{}), to: Integrity, as: :self_view

  defdelegate default_integrity_reconciliation_limit(),
    to: Integrity,
    as: :default_reconciliation_limit

  defdelegate max_integrity_reconciliation_limit(), to: Integrity, as: :max_reconciliation_limit
  defdelegate run_pickup_watchdog(attrs \\ %{}), to: PickupWatchdog, as: :run

  defdelegate ops_pickup_watchdog_summary(attrs \\ %{}),
    to: PickupWatchdogSummary,
    as: :fetch

  defdelegate list_notifications_for_user(user_id, attrs \\ %{}),
    to: Notifications,
    as: :list_for_user

  defdelegate ops_list_notifications_for_ride(ride_id, attrs \\ %{}),
    to: Notifications,
    as: :list_for_ride

  defdelegate retry_pending_notifications(attrs \\ %{}),
    to: NotificationRetry,
    as: :run

  def ack_notification_for_user(
        user_id,
        notification_id,
        acked_at \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ) do
    Notifications.ack_for_user(user_id, notification_id, acked_at)
  end
end
