defmodule LiddrWeb.SubscriptionSerializer do
  def current_payload(payload) do
    %{
      driver: %{
        user_id: payload.driver.user_id,
        subscription_status: payload.driver.subscription_status,
        is_available: payload.driver.is_available
      },
      subscription: payload.subscription && subscription_payload(payload.subscription),
      latest_payment: payload.latest_payment && payment_history_payload(payload.latest_payment)
    }
  end

  def payment_created_payload(payload) do
    %{
      subscription: subscription_payload(payload.subscription),
      payment: payment_history_payload(payload.payment),
      callback_url: payload.callback_url
    }
  end

  def payment_history_payload(payment) do
    %{
      id: payment.id,
      subscription_id: payment.subscription_id,
      status: payment.status,
      provider: payment.provider,
      payment_channel: payment.payment_channel,
      amount_kes: payment.amount_kes,
      currency: payment.currency,
      phone_e164: payment.phone_e164,
      merchant_request_id: payment.merchant_request_id,
      checkout_request_id: payment.checkout_request_id,
      mpesa_receipt_number: payment.mpesa_receipt_number,
      transaction_id: payment.transaction_id,
      result_code: payment.result_code,
      result_desc: payment.result_desc,
      requested_at: payment.requested_at,
      callback_received_at: payment.callback_received_at,
      paid_at: payment.paid_at,
      inserted_at: payment.inserted_at
    }
  end

  def driver_lookup_payload(payload) do
    %{
      driver: %{
        user_id: payload.driver.user_id,
        account_status: payload.driver.account_status,
        verification_status: payload.driver.verification_status,
        subscription_status: payload.driver.subscription_status,
        is_available: payload.driver.is_available,
        last_seen_at: payload.driver.last_seen_at,
        last_online_at: payload.driver.last_online_at
      },
      subscription: payload.subscription && subscription_payload(payload.subscription),
      payments: Enum.map(payload.payments, &ops_payment_payload/1)
    }
  end

  def ops_payment_payload(payment) do
    %{
      id: payment.id,
      subscription_id: payment.subscription_id,
      driver_id: payment.driver_id,
      status: payment.status,
      provider: payment.provider,
      payment_channel: payment.payment_channel,
      amount_kes: payment.amount_kes,
      currency: payment.currency,
      phone_e164: payment.phone_e164,
      merchant_request_id: payment.merchant_request_id,
      checkout_request_id: payment.checkout_request_id,
      mpesa_receipt_number: payment.mpesa_receipt_number,
      result_code: payment.result_code,
      result_desc: payment.result_desc,
      callback_received_at: payment.callback_received_at,
      paid_at: payment.paid_at,
      requested_at: payment.requested_at,
      inserted_at: payment.inserted_at,
      subscription: subscription_snapshot(payment.subscription)
    }
  end

  def subscription_payload(subscription) do
    %{
      id: subscription.id,
      driver_id: subscription.driver_id,
      vehicle_category_id: subscription.vehicle_category_id,
      week_start: subscription.week_start,
      week_end: subscription.week_end,
      amount_kes: subscription.amount_kes,
      status: subscription.status,
      activated_at: subscription.activated_at,
      expired_at: subscription.expired_at
    }
  end

  defp subscription_snapshot(%Ecto.Association.NotLoaded{}), do: nil
  defp subscription_snapshot(nil), do: nil

  defp subscription_snapshot(subscription) do
    %{
      id: subscription.id,
      status: subscription.status,
      week_start: subscription.week_start,
      week_end: subscription.week_end
    }
  end
end
