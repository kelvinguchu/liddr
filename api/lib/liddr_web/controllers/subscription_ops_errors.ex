defmodule LiddrWeb.SubscriptionOpsErrors do
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  def render(conn, :driver_profile_not_found),
    do: error_response(conn, :not_found, "DRIVER_PROFILE_NOT_FOUND", "Driver profile not found")

  def render(conn, :subscription_payment_not_found),
    do:
      error_response(
        conn,
        :not_found,
        "SUBSCRIPTION_PAYMENT_NOT_FOUND",
        "Subscription payment not found"
      )

  def render(conn, :invalid_driver_user_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DRIVER_USER_ID",
        "driver_user_id must be a positive integer"
      )

  def render(conn, :invalid_checkout_request_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_CHECKOUT_REQUEST_ID",
        "checkout_request_id is required"
      )

  def render(conn, :missing_transaction_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_TRANSACTION_ID",
        "Transaction ID is required to query M-Pesa transaction status"
      )

  def render(conn, :missing_mpesa_callback_base_url),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_CALLBACK_BASE_URL",
        "MPESA_CALLBACK_BASE_URL is not configured"
      )

  def render(conn, :missing_callback_token_config),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MISSING_CALLBACK_TOKEN_CONFIG",
        "MPESA_CALLBACK_TOKEN is not configured"
      )

  def render(conn, {:missing_mpesa_env, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_ENV",
        "Missing required M-Pesa environment variable: #{key}"
      )

  def render(conn, {:missing_mpesa_field, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_MPESA_FIELD",
        "Missing required M-Pesa field: #{key}"
      )

  def render(conn, {:invalid_mpesa_field, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_MPESA_FIELD",
        "Invalid M-Pesa field: #{key}"
      )

  def render(conn, {:mpesa_http_error, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "MPESA_UPSTREAM_HTTP_ERROR",
        "M-Pesa #{operation_label(operation)} failed with HTTP #{upstream_status}",
        %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
      )

  def render(conn, {:mpesa_invalid_response, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "MPESA_UPSTREAM_INVALID_RESPONSE",
        "M-Pesa #{operation_label(operation)} returned an invalid response",
        %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
      )

  def render(conn, {:mpesa_transport_error, operation, reason}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_UPSTREAM_TRANSPORT_ERROR",
        "M-Pesa #{operation_label(operation)} transport error",
        %{operation: operation, reason: reason}
      )

  def render(conn, :mpesa_c2b_register_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_C2B_REGISTER_FAILED",
        "Unable to register M-Pesa C2B callback URLs"
      )

  def render(conn, :mpesa_transaction_status_query_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TRANSACTION_STATUS_QUERY_FAILED",
        "Unable to query M-Pesa transaction status"
      )

  def render(conn, _unknown),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SUBSCRIPTION_OPS_LOOKUP_ERROR",
        "Unable to process subscription lookup"
      )

  defp error_response(conn, status, code, message, details \\ nil) do
    payload =
      if is_map(details) do
        %{error: %{code: code, message: message, details: details}}
      else
        %{error: %{code: code, message: message}}
      end

    conn
    |> put_status(status)
    |> json(payload)
  end

  defp operation_label(:oauth_token), do: "OAuth token request"
  defp operation_label(:c2b_register), do: "C2B URL registration"
  defp operation_label(:transaction_status_query), do: "transaction status query"
  defp operation_label(_unknown), do: "request"
end
