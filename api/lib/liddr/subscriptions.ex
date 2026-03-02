defmodule Liddr.Subscriptions do
  require Logger

  alias Liddr.Subscriptions.C2BCallback
  alias Liddr.Subscriptions.Lookup
  alias Liddr.Subscriptions.MpesaCallback
  alias Liddr.Subscriptions.Payments
  alias Liddr.Subscriptions.Reconciliation
  alias Liddr.Subscriptions.StkCallback
  alias Liddr.Subscriptions.TxStatus
  alias Liddr.Subscriptions.TxStatusCallback

  def current_subscription(driver_user_id),
    do: Lookup.current_subscription(driver_user_id)

  def list_payment_history(driver_user_id, attrs \\ %{}),
    do: Lookup.list_payment_history(driver_user_id, attrs)

  def ops_lookup_driver(driver_user_id, attrs \\ %{}),
    do: Lookup.ops_lookup_driver(driver_user_id, attrs)

  def ops_lookup_payment_by_checkout(checkout_request_id),
    do: Lookup.ops_lookup_payment_by_checkout(checkout_request_id)

  def initiate_payment(driver_user_id, attrs \\ %{}),
    do: Payments.initiate_payment(driver_user_id, attrs)

  def register_c2b_urls,
    do: Payments.register_c2b_urls()

  def query_transaction_status_by_checkout(checkout_request_id, attrs \\ %{}),
    do: TxStatus.query_by_checkout(checkout_request_id, attrs, mpesa_client_module())

  def reconcile_pending_payments(attrs \\ %{}),
    do: Reconciliation.reconcile_pending_payments(attrs)

  def handle_stk_callback(payload) do
    case StkCallback.handle(payload) do
      {:error, :subscription_payment_not_found} ->
        Logger.warning("[mpesa.stk_callback] unmatched callback accepted for reconciliation")

        {:ok, %{status: :deferred}}

      other ->
        other
    end
  end

  def handle_c2b_callback(payload) do
    case C2BCallback.handle(payload) do
      {:error, :subscription_not_found} ->
        Logger.warning("[mpesa.c2b_callback] unmatched bill ref accepted for reconciliation")

        {:ok, %{status: :deferred}}

      other ->
        other
    end
  end

  def handle_transaction_status_callback(payload) do
    case TxStatusCallback.handle(payload) do
      {:error, :subscription_payment_not_found} ->
        Logger.warning(
          "[mpesa.tx_status_callback] unmatched transaction callback accepted for reconciliation"
        )

        {:ok, %{status: :deferred}}

      other ->
        other
    end
  end

  def verify_callback_token(token),
    do: MpesaCallback.verify_callback_token(token)

  def callback_token_transport,
    do: MpesaCallback.callback_token_transport()

  defp mpesa_client_module,
    do: Application.get_env(:liddr, :mpesa_client, Liddr.Payments.Mpesa.Client)
end
