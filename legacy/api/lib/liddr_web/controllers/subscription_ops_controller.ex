defmodule LiddrWeb.SubscriptionOpsController do
  use LiddrWeb, :controller

  alias Liddr.Payments.Mpesa.Sanitizer
  alias Liddr.Subscriptions
  alias LiddrWeb.SubscriptionOpsErrors
  alias LiddrWeb.Idempotency
  alias LiddrWeb.SubscriptionSerializer

  def driver_lookup(conn, %{"driver_user_id" => driver_user_id} = params) do
    with {:ok, parsed_driver_user_id} <- parse_positive_integer(driver_user_id),
         {:ok, payload} <- Subscriptions.ops_lookup_driver(parsed_driver_user_id, params) do
      json(conn, %{data: SubscriptionSerializer.driver_lookup_payload(payload)})
    else
      {:error, reason} -> SubscriptionOpsErrors.render(conn, reason)
    end
  end

  def payment_lookup(conn, %{"checkout_request_id" => checkout_request_id}) do
    case Subscriptions.ops_lookup_payment_by_checkout(checkout_request_id) do
      {:ok, payment} ->
        json(conn, %{data: %{payment: SubscriptionSerializer.ops_payment_payload(payment)}})

      {:error, reason} ->
        SubscriptionOpsErrors.render(conn, reason)
    end
  end

  def register_c2b_urls(conn, _params) do
    Idempotency.execute(
      conn,
      "ops.subscription.c2b_register",
      conn.body_params,
      fn ->
        case Subscriptions.register_c2b_urls() do
          {:ok, payload} ->
            {:ok, 200,
             %{
               data: %{
                 validation_url: payload.validation_url,
                 confirmation_url: payload.confirmation_url,
                 response_payload: Sanitizer.payload(payload.result.response_payload)
               }
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &SubscriptionOpsErrors.render/2
    )
  end

  def query_tx_status(conn, %{"checkout_request_id" => checkout_request_id} = params) do
    Idempotency.execute(
      conn,
      "ops.subscription.tx_status_query:#{checkout_request_id}",
      params,
      fn ->
        case Subscriptions.query_transaction_status_by_checkout(checkout_request_id, params) do
          {:ok, payload} ->
            {:ok, 200,
             %{
               data: %{
                 payment: SubscriptionSerializer.ops_payment_payload(payload.payment),
                 response_payload: Sanitizer.payload(payload.query_result.response_payload),
                 result_url: payload.result_url,
                 timeout_url: payload.timeout_url
               }
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &SubscriptionOpsErrors.render/2
    )
  end

  defp parse_positive_integer(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_driver_user_id}
    end
  end
end
