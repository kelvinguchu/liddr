defmodule Liddr.Rides.NotificationSummary do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.RideNotification

  @critical_event_types ~w(
    ride_cancelled
    trip_cancelled
    driver_offline_detected
    reassigning_driver
    ride_message_communication_restricted
    rider_no_show
    send_recipient_confirmed
  )

  def for_user(user_id) when is_integer(user_id) and user_id > 0 do
    unread_count =
      Repo.one(
        from n in RideNotification,
          where: n.recipient_user_id == ^user_id and n.socket_status != "acked",
          select: count()
      ) || 0

    critical_count =
      Repo.one(
        from n in RideNotification,
          where:
            n.recipient_user_id == ^user_id and n.socket_status != "acked" and
              n.event_type in ^@critical_event_types,
          select: count()
      ) || 0

    latest_notification_at =
      Repo.one(
        from n in RideNotification,
          where: n.recipient_user_id == ^user_id,
          select: max(n.inserted_at)
      )

    {:ok,
     %{
       unread_count: unread_count,
       critical_count: critical_count,
       latest_notification_at: latest_notification_at
     }}
  end

  def for_user(_user_id), do: {:error, :invalid_user_id}
end
