defmodule LiddrWeb.RideOpsController do
  use LiddrWeb, :controller

  alias Liddr.Rides
  alias Liddr.Rides.RideNotification
  alias LiddrWeb.Idempotency

  def integrity_lookup(conn, %{"user_id" => user_id} = params) do
    with {:ok, parsed_user_id} <- parse_positive_integer(user_id, :invalid_user_id),
         {:ok, payload} <- Rides.ops_lookup_user_integrity(parsed_user_id, params) do
      json(conn, %{data: integrity_payload(payload)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def reconcile_prepay_modes(conn, params) do
    Idempotency.execute(
      conn,
      "ops.ride.reconcile_prepay_modes",
      params,
      fn ->
        with {:ok, limit} <- parse_reconciliation_limit(params),
             {:ok, results} <- Rides.expire_due_rider_prepay_modes(%{"limit" => limit}) do
          {:ok, 200,
           %{
             data: %{
               processed: length(results),
               reconciled: length(results),
               results: results
             }
           }}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def pickup_watchdog_summary(conn, params) do
    case Rides.ops_pickup_watchdog_summary(params) do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def offer_lock_health(conn, _params) do
    case Rides.ops_offer_lock_health() do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def ride_notifications(conn, %{"ride_id" => ride_id} = params) do
    with {:ok, parsed_ride_id} <- parse_positive_integer(ride_id, :invalid_ride_id),
         {:ok, notifications} <- Rides.ops_list_notifications_for_ride(parsed_ride_id, params) do
      json(conn, %{data: %{notifications: Enum.map(notifications, &notification_payload/1)}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp integrity_payload(payload) do
    %{
      user: %{
        id: payload.user.id,
        account_status: payload.user.account_status,
        ride_booking_mode: payload.user.ride_booking_mode,
        ride_booking_mode_until: payload.user.ride_booking_mode_until
      },
      policy: payload.policy,
      prepay_mode: payload.prepay_mode,
      counters: payload.counters,
      recent_chargeable_events: payload.recent_chargeable_events
    }
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

  defp render_error(conn, :user_not_found),
    do: error_response(conn, :not_found, "USER_NOT_FOUND", "User not found")

  defp render_error(conn, :invalid_user_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_USER_ID",
        "user_id must be a positive integer"
      )

  defp render_error(conn, :invalid_ride_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RIDE_ID",
        "ride_id must be a positive integer"
      )

  defp render_error(conn, :invalid_reconciliation_limit),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_PREPAY_RECONCILIATION_LIMIT",
        "limit must be an integer between 1 and 1000"
      )

  defp render_error(conn, :invalid_since),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_SINCE",
        "since must be a valid ISO8601 datetime"
      )

  defp render_error(conn, :invalid_pickup_watchdog_limit),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_PICKUP_WATCHDOG_LIMIT",
        "limit must be an integer between 1 and 200"
      )

  defp render_error(conn, _reason),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RIDE_INTEGRITY_OPS_ERROR",
        "Unable to process ride integrity operation"
      )

  defp parse_positive_integer(value, error_code) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, error_code}
    end
  end

  defp parse_reconciliation_limit(params) do
    value = Map.get(params, "limit") || Map.get(params, :limit)
    max_limit = Rides.max_integrity_reconciliation_limit()
    default_limit = Rides.default_integrity_reconciliation_limit()

    case value do
      nil ->
        {:ok, default_limit}

      parsed when is_integer(parsed) and parsed >= 1 and parsed <= max_limit ->
        {:ok, parsed}

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, ""} when parsed >= 1 and parsed <= max_limit -> {:ok, parsed}
          _ -> {:error, :invalid_reconciliation_limit}
        end

      _ ->
        {:error, :invalid_reconciliation_limit}
    end
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
