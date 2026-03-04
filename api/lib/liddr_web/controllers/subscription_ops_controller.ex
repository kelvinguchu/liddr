defmodule LiddrWeb.SubscriptionOpsController do
  use LiddrWeb, :controller

  alias Liddr.Subscriptions
  alias LiddrWeb.SubscriptionSerializer

  def driver_lookup(conn, %{"driver_user_id" => driver_user_id} = params) do
    with {:ok, parsed_driver_user_id} <- parse_positive_integer(driver_user_id),
         {:ok, payload} <- Subscriptions.ops_lookup_driver(parsed_driver_user_id, params) do
      json(conn, %{data: SubscriptionSerializer.driver_lookup_payload(payload)})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def payment_lookup(conn, %{"checkout_request_id" => checkout_request_id}) do
    case Subscriptions.ops_lookup_payment_by_checkout(checkout_request_id) do
      {:ok, payment} ->
        json(conn, %{data: %{payment: SubscriptionSerializer.ops_payment_payload(payment)}})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def register_c2b_urls(conn, _params) do
    case Subscriptions.register_c2b_urls() do
      {:ok, payload} ->
        json(conn, %{
          data: %{
            validation_url: payload.validation_url,
            confirmation_url: payload.confirmation_url,
            response_payload: payload.result.response_payload
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def query_tx_status(conn, %{"checkout_request_id" => checkout_request_id} = params) do
    case Subscriptions.query_transaction_status_by_checkout(checkout_request_id, params) do
      {:ok, payload} ->
        json(conn, %{
          data: %{
            payment: SubscriptionSerializer.ops_payment_payload(payload.payment),
            response_payload: payload.query_result.response_payload,
            result_url: payload.result_url,
            timeout_url: payload.timeout_url
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, :driver_profile_not_found),
    do:
      error_response(
        conn,
        :not_found,
        "DRIVER_PROFILE_NOT_FOUND",
        "Driver profile not found"
      )

  defp render_error(conn, :subscription_payment_not_found),
    do:
      error_response(
        conn,
        :not_found,
        "SUBSCRIPTION_PAYMENT_NOT_FOUND",
        "Subscription payment not found"
      )

  defp render_error(conn, :invalid_driver_user_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DRIVER_USER_ID",
        "driver_user_id must be a positive integer"
      )

  defp render_error(conn, :invalid_checkout_request_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_CHECKOUT_REQUEST_ID",
        "checkout_request_id is required"
      )

  defp render_error(conn, :missing_transaction_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_TRANSACTION_ID",
        "Transaction ID is required to query M-Pesa transaction status"
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

  defp render_error(conn, {:invalid_mpesa_field, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_MPESA_FIELD",
        "Invalid M-Pesa field: #{key}"
      )

  defp render_error(conn, {:mpesa_http_error, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "MPESA_UPSTREAM_HTTP_ERROR",
        "M-Pesa #{operation_label(operation)} failed with HTTP #{upstream_status}",
        %{
          operation: operation,
          upstream_status: upstream_status,
          upstream_body: upstream_body
        }
      )

  defp render_error(conn, {:mpesa_invalid_response, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "MPESA_UPSTREAM_INVALID_RESPONSE",
        "M-Pesa #{operation_label(operation)} returned an invalid response",
        %{
          operation: operation,
          upstream_status: upstream_status,
          upstream_body: upstream_body
        }
      )

  defp render_error(conn, {:mpesa_transport_error, operation, reason}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_UPSTREAM_TRANSPORT_ERROR",
        "M-Pesa #{operation_label(operation)} transport error",
        %{operation: operation, reason: reason}
      )

  defp render_error(conn, :mpesa_c2b_register_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_C2B_REGISTER_FAILED",
        "Unable to register M-Pesa C2B callback URLs"
      )

  defp render_error(conn, :mpesa_transaction_status_query_failed),
    do:
      error_response(
        conn,
        :service_unavailable,
        "MPESA_TRANSACTION_STATUS_QUERY_FAILED",
        "Unable to query M-Pesa transaction status"
      )

  defp render_error(conn, _unknown),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SUBSCRIPTION_OPS_LOOKUP_ERROR",
        "Unable to process subscription lookup"
      )

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_driver_user_id}
    end
  end

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
