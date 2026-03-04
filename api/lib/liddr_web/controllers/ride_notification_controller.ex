defmodule LiddrWeb.RideNotificationController do
  use LiddrWeb, :controller

  alias Liddr.Rides
  alias Liddr.Rides.RideNotification

  @error_mappings %{
    notification_not_found:
      {:not_found, "NOTIFICATION_NOT_FOUND", "Ride notification was not found"}
  }

  def index(conn, params) do
    user_id = conn.assigns.current_user.id

    case Rides.list_notifications_for_user(user_id, params) do
      {:ok, notifications} ->
        json(conn, %{data: %{notifications: Enum.map(notifications, &notification_payload/1)}})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def ack(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user.id
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Rides.ack_notification_for_user(user_id, id, now) do
      {:ok, notification} ->
        json(conn, %{data: %{notification: notification_payload(notification)}})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, reason) do
    case Map.get(@error_mappings, reason) do
      {status, code, message} ->
        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "RIDE_NOTIFICATION_ERROR", message: "Unable to process request"}
        })
    end
  end

  defp notification_payload(%RideNotification{} = notification) do
    %{
      id: notification.id,
      ride_id: notification.ride_id,
      recipient_user_id: notification.recipient_user_id,
      event_type: notification.event_type,
      socket_status: notification.socket_status,
      push_status: notification.push_status,
      poll_status: notification.poll_status,
      last_attempt_at: notification.last_attempt_at,
      acked_at: notification.acked_at,
      attempt_count: notification.attempt_count,
      payload: notification.payload,
      inserted_at: notification.inserted_at
    }
  end
end
