defmodule Liddr.Subscriptions.StkCallback do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Payments.Mpesa.Parser
  alias Liddr.Repo
  alias Liddr.Subscriptions.Activation
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.Subscriptions.WebhookEvents

  @final_payment_statuses ~w(success failed cancelled timeout)

  def handle(payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, parsed} <- Parser.parse_stk_callback(payload) do
      external_ref = callback_external_ref(parsed, payload)

      Repo.transaction(fn ->
        event = WebhookEvents.get_or_create!("stk_callback", external_ref, payload)

        if event.processed_at do
          %{status: :duplicate}
        else
          payment = find_payment_for_callback!(parsed)
          ensure_callback_integrity!(payment, parsed)

          updated_payment =
            if payment.status in @final_payment_statuses do
              payment
            else
              apply_callback_to_payment!(payment, parsed, payload, now)
            end

          if updated_payment.status == "success" do
            Activation.activate_subscription!(updated_payment, now)
          end

          WebhookEvents.mark_processed!(event, now)
          %{status: :processed, payment: updated_payment}
        end
      end)
      |> unwrap_transaction_result()
    end
  end

  defp find_payment_for_callback!(parsed) do
    checkout_request_id = parsed.checkout_request_id
    merchant_request_id = parsed.merchant_request_id

    query =
      cond do
        is_binary(checkout_request_id) and checkout_request_id != "" ->
          from p in SubscriptionPayment,
            where: p.checkout_request_id == ^checkout_request_id,
            order_by: [desc: p.inserted_at],
            lock: "FOR UPDATE",
            limit: 1

        is_binary(merchant_request_id) and merchant_request_id != "" ->
          from p in SubscriptionPayment,
            where: p.merchant_request_id == ^merchant_request_id,
            order_by: [desc: p.inserted_at],
            lock: "FOR UPDATE",
            limit: 1

        true ->
          Repo.rollback(:subscription_payment_not_found)
      end

    Repo.one(query) || Repo.rollback(:subscription_payment_not_found)
  end

  defp ensure_callback_integrity!(payment, parsed) do
    if parsed.result_code == 0 do
      ensure_callback_amount_matches!(payment.amount_kes, parsed.amount_kes)
      ensure_callback_phone_matches!(payment.phone_e164, parsed.phone_e164)
    end

    :ok
  end

  defp ensure_callback_amount_matches!(_expected_amount, nil),
    do: Repo.rollback(:callback_amount_mismatch)

  defp ensure_callback_amount_matches!(expected_amount, parsed_amount) do
    if D.compare(expected_amount, parsed_amount) == :eq,
      do: :ok,
      else: Repo.rollback(:callback_amount_mismatch)
  end

  defp ensure_callback_phone_matches!(nil, _parsed_phone), do: :ok

  defp ensure_callback_phone_matches!(_expected_phone, nil),
    do: Repo.rollback(:callback_phone_mismatch)

  defp ensure_callback_phone_matches!(expected_phone, parsed_phone) do
    if expected_phone == parsed_phone,
      do: :ok,
      else: Repo.rollback(:callback_phone_mismatch)
  end

  defp apply_callback_to_payment!(payment, parsed, payload, now) do
    payment_status = Parser.payment_status_from_result_code(parsed.result_code)

    attrs =
      %{
        "status" => payment_status,
        "result_code" => parsed.result_code,
        "result_desc" => parsed.result_desc,
        "callback_received_at" => now,
        "callback_payload" => payload,
        "phone_e164" => parsed.phone_e164 || payment.phone_e164,
        "merchant_request_id" => parsed.merchant_request_id || payment.merchant_request_id,
        "checkout_request_id" => parsed.checkout_request_id || payment.checkout_request_id,
        "mpesa_receipt_number" => parsed.mpesa_receipt_number || payment.mpesa_receipt_number,
        "paid_at" => if(payment_status == "success", do: now, else: nil)
      }
      |> maybe_put_amount(parsed.amount_kes)

    payment
    |> SubscriptionPayment.create_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp callback_external_ref(parsed, payload) do
    parsed.checkout_request_id || parsed.merchant_request_id ||
      "payload_" <> sha256_hex(payload)
  end

  defp sha256_hex(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_amount(attrs, nil), do: attrs
  defp maybe_put_amount(attrs, amount), do: Map.put(attrs, "amount_kes", amount)

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
