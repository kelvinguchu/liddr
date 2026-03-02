defmodule Liddr.Subscriptions.TxStatus do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Subscriptions.MpesaCallback
  alias Liddr.Subscriptions.SubscriptionPayment

  def query_by_checkout(checkout_request_id, attrs, mpesa_client_module) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, payment} <- find_payment_for_checkout(checkout_request_id),
         {:ok, transaction_id} <- resolve_transaction_id(attrs, payment),
         {:ok, result_url} <- MpesaCallback.tx_status_result_url(attrs),
         {:ok, timeout_url} <- MpesaCallback.tx_status_timeout_url(attrs),
         {:ok, query_result} <-
           mpesa_client_module.query_transaction_status(%{
             transaction_id: transaction_id,
             result_url: result_url,
             timeout_url: timeout_url,
             remarks: get_value(attrs, :remarks),
             occasion: get_value(attrs, :occasion)
           }),
         {:ok, updated_payment} <-
           persist_transaction_status_query(payment.id, transaction_id, query_result, now) do
      {:ok,
       %{
         payment: updated_payment,
         query_result: query_result,
         result_url: result_url,
         timeout_url: timeout_url
       }}
    end
  end

  defp find_payment_for_checkout(checkout_request_id) do
    normalized_checkout_request_id = normalize_text(checkout_request_id)

    case normalized_checkout_request_id do
      nil ->
        {:error, :invalid_checkout_request_id}

      value ->
        payment =
          Repo.one(
            from p in SubscriptionPayment,
              where: p.checkout_request_id == ^value,
              order_by: [desc: p.inserted_at],
              limit: 1
          )

        if payment, do: {:ok, payment}, else: {:error, :subscription_payment_not_found}
    end
  end

  defp resolve_transaction_id(attrs, payment) do
    transaction_id =
      normalize_text(
        get_value(attrs, :transaction_id) || payment.transaction_id ||
          payment.mpesa_receipt_number
      )

    if is_nil(transaction_id), do: {:error, :missing_transaction_id}, else: {:ok, transaction_id}
  end

  defp persist_transaction_status_query(payment_id, transaction_id, query_result, now) do
    response_payload = query_result.response_payload

    Repo.transaction(fn ->
      payment =
        Repo.one(
          from p in SubscriptionPayment,
            where: p.id == ^payment_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:subscription_payment_not_found)

      payment
      |> SubscriptionPayment.create_changeset(%{
        "transaction_id" => transaction_id,
        "conversation_id" =>
          normalize_text(Map.get(response_payload, "ConversationID")) || payment.conversation_id,
        "originator_conversation_id" =>
          normalize_text(Map.get(response_payload, "OriginatorConversationID")) ||
            payment.originator_conversation_id,
        "status_query_payload" => %{
          "requested_at" => now,
          "request_payload" => query_result.request_payload,
          "response_payload" => response_payload
        }
      })
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> parsed
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
