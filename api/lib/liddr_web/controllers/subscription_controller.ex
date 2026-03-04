defmodule LiddrWeb.SubscriptionController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Subscriptions
  alias LiddrWeb.SubscriptionSerializer

  def current(conn, _params) do
    driver_user_id = conn.assigns.current_user.id

    case Subscriptions.current_subscription(driver_user_id) do
      {:ok, payload} ->
        json(conn, %{data: SubscriptionSerializer.current_payload(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def pay(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Subscriptions.initiate_payment(driver_user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: SubscriptionSerializer.payment_created_payload(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def history(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Subscriptions.list_payment_history(driver_user_id, params) do
      {:ok, payments} ->
        json(conn, %{
          data: %{payments: Enum.map(payments, &SubscriptionSerializer.payment_history_payload/1)}
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, :driver_profile_not_found),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "DRIVER_PROFILE_NOT_FOUND",
        "Driver profile must be initialized first"
      )

  defp render_error(conn, :driver_phone_missing),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "DRIVER_PHONE_MISSING",
        "Driver phone number is required to initiate M-Pesa payment"
      )

  defp render_error(conn, :invalid_mpesa_phone),
    do: error_response(conn, :unprocessable_entity, "INVALID_MPESA_PHONE", "Invalid M-Pesa phone")

  defp render_error(conn, :vehicle_category_not_found),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "VEHICLE_CATEGORY_NOT_FOUND",
        "Active vehicle category was not found for the driver"
      )

  defp render_error(conn, :subscription_already_active),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SUBSCRIPTION_ALREADY_ACTIVE",
        "Current subscription is already active"
      )

  defp render_error(conn, :payment_already_pending),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "PAYMENT_ALREADY_PENDING",
        "There is already a pending M-Pesa payment for this subscription"
      )

  defp render_error(conn, :missing_mpesa_callback_base_url),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_CALLBACK_BASE_URL",
        "MPESA_CALLBACK_BASE_URL is not configured"
      )

  defp render_error(conn, :missing_callback_token_config),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MISSING_CALLBACK_TOKEN_CONFIG",
        "MPESA_CALLBACK_TOKEN is not configured"
      )

  defp render_error(conn, {:missing_mpesa_env, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_ENV",
        "Missing required M-Pesa environment variable: #{key}"
      )

  defp render_error(conn, {:missing_mpesa_field, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_FIELD",
        "Missing required M-Pesa field: #{key}"
      )

  defp render_error(conn, :invalid_mpesa_amount),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_MPESA_AMOUNT",
        "M-Pesa amount is invalid"
      )

  defp render_error(conn, :mpesa_token_request_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TOKEN_REQUEST_FAILED",
        "Unable to acquire M-Pesa access token"
      )

  defp render_error(conn, {:mpesa_http_error, :oauth_token, _status, _body}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TOKEN_REQUEST_FAILED",
        "Unable to acquire M-Pesa access token"
      )

  defp render_error(conn, {:mpesa_invalid_response, :oauth_token, _status, _body}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TOKEN_REQUEST_FAILED",
        "Unable to acquire M-Pesa access token"
      )

  defp render_error(conn, {:mpesa_transport_error, :oauth_token, _reason}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TOKEN_REQUEST_FAILED",
        "Unable to acquire M-Pesa access token"
      )

  defp render_error(conn, :mpesa_stk_request_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_STK_REQUEST_FAILED",
        "Unable to initiate M-Pesa STK push"
      )

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, _reason),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SUBSCRIPTION_PAYMENT_ERROR",
        "Unable to process subscription payment"
      )

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
