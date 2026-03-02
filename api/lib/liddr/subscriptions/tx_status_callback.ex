defmodule Liddr.Subscriptions.TxStatusCallback do
  import Ecto.Query

  alias Liddr.Payments.Mpesa.Parser
  alias Liddr.Repo
  alias Liddr.Subscriptions.Activation
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.Subscriptions.WebhookEvents

  @final_payment_statuses ~w(success failed cancelled timeout)

  def handle(payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, parsed} <- Parser.parse_transaction_status_callback(payload) do
      external_ref =
        parsed.transaction_id || parsed.conversation_id || parsed.originator_conversation_id ||
          "payload_" <> sha256_hex(payload)

      Repo.transaction(fn ->
        event = WebhookEvents.get_or_create!("tx_status_callback", external_ref, payload)

        if event.processed_at do
          %{status: :duplicate}
        else
          payment = find_payment_for_tx_status_callback!(parsed)
          updated_payment = apply_tx_status_to_payment!(payment, parsed, payload, now)

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

  defp find_payment_for_tx_status_callback!(parsed) do
    query =
      cond do
        is_binary(parsed.transaction_id) and parsed.transaction_id != "" ->
          from p in SubscriptionPayment,
            where: p.transaction_id == ^parsed.transaction_id,
            order_by: [desc: p.inserted_at],
            lock: "FOR UPDATE",
            limit: 1

        is_binary(parsed.conversation_id) and parsed.conversation_id != "" ->
          from p in SubscriptionPayment,
            where: p.conversation_id == ^parsed.conversation_id,
            order_by: [desc: p.inserted_at],
            lock: "FOR UPDATE",
            limit: 1

        is_binary(parsed.originator_conversation_id) and parsed.originator_conversation_id != "" ->
          from p in SubscriptionPayment,
            where: p.originator_conversation_id == ^parsed.originator_conversation_id,
            order_by: [desc: p.inserted_at],
            lock: "FOR UPDATE",
            limit: 1

        true ->
          Repo.rollback(:subscription_payment_not_found)
      end

    Repo.one(query) || Repo.rollback(:subscription_payment_not_found)
  end

  defp apply_tx_status_to_payment!(payment, parsed, payload, now) do
    proposed_status = Parser.payment_status_from_result_code(parsed.result_code)

    payment_status =
      if payment.status in @final_payment_statuses, do: payment.status, else: proposed_status

    payment
    |> SubscriptionPayment.create_changeset(%{
      "status" => payment_status,
      "result_code" => parsed.result_code,
      "result_desc" => parsed.result_desc,
      "transaction_id" => parsed.transaction_id || payment.transaction_id,
      "conversation_id" => parsed.conversation_id || payment.conversation_id,
      "originator_conversation_id" =>
        parsed.originator_conversation_id || payment.originator_conversation_id,
      "callback_received_at" => now,
      "callback_payload" => payload,
      "paid_at" =>
        if(payment_status == "success", do: payment.paid_at || now, else: payment.paid_at)
    })
    |> Repo.update()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp sha256_hex(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
