defmodule Liddr.Subscriptions.Reconciliation do
  import Ecto.Query

  alias Liddr.Payments.Mpesa.Client
  alias Liddr.Payments.Mpesa.Parser
  alias Liddr.Repo
  alias Liddr.Subscriptions.Activation
  alias Liddr.Subscriptions.ReconciliationPolicy
  alias Liddr.Subscriptions.SubscriptionPayment

  @pending_payment_statuses ~w(initiated pending_callback)
  @final_payment_statuses ~w(success failed cancelled timeout)

  def reconcile_pending_payments(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    policy = ReconciliationPolicy.resolve(attrs)
    eligible_before = DateTime.add(now, -policy.grace_seconds, :second)

    payments =
      Repo.all(
        from p in SubscriptionPayment,
          where: p.status in ^@pending_payment_statuses and p.requested_at <= ^eligible_before,
          order_by: [asc: p.requested_at, asc: p.id],
          limit: ^policy.limit
      )

    results =
      Enum.map(payments, fn payment ->
        reconcile_payment(payment.id, now, policy.max_age_seconds)
      end)

    {:ok, results}
  end

  defp reconcile_payment(payment_id, now, max_age_seconds) do
    case prepare_reconciliation(payment_id, now, max_age_seconds) do
      {:ok, {:completed, result}} ->
        result

      {:ok, {:query, checkout_request_id}} ->
        run_status_query(payment_id, checkout_request_id, now)

      {:error, reason} ->
        %{payment_id: payment_id, status: "error", reason: inspect(reason)}
    end
  end

  defp prepare_reconciliation(payment_id, now, max_age_seconds) do
    Repo.transaction(fn ->
      payment =
        Repo.one(
          from p in SubscriptionPayment,
            where: p.id == ^payment_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:subscription_payment_not_found)

      cond do
        payment.status in @final_payment_statuses ->
          {:completed, %{payment_id: payment_id, status: "already_final"}}

        DateTime.diff(now, payment.requested_at, :second) >= max_age_seconds ->
          updated_payment = mark_payment_timeout!(payment, now)
          {:completed, %{payment_id: payment_id, status: updated_payment.status}}

        is_nil(normalize_text(payment.checkout_request_id)) ->
          updated_payment =
            update_payment_status_from_query!(
              payment,
              -1,
              "Missing checkout request ID for STK query",
              %{"reason" => "missing_checkout_request_id"},
              now
            )

          {:completed, %{payment_id: payment_id, status: updated_payment.status}}

        true ->
          {:query, payment.checkout_request_id}
      end
    end)
    |> unwrap_transaction_result()
  end

  defp run_status_query(payment_id, checkout_request_id, now) do
    case mpesa_client_module().query_stk_status(checkout_request_id) do
      {:ok, query_result} ->
        persist_status_query_result(payment_id, query_result, now)

      {:error, reason} ->
        %{payment_id: payment_id, status: "query_failed", reason: inspect(reason)}
    end
  end

  defp persist_status_query_result(payment_id, query_result, now) do
    Repo.transaction(fn ->
      payment =
        Repo.one(
          from p in SubscriptionPayment,
            where: p.id == ^payment_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:subscription_payment_not_found)

      if payment.status in @final_payment_statuses do
        %{payment_id: payment_id, status: "already_final"}
      else
        response_payload = query_result.response_payload
        updated_payment = apply_status_query_to_payment!(payment, query_result, now)

        %{
          payment_id: payment_id,
          status: updated_payment.status,
          result_code: parse_result_code(Map.get(response_payload, "ResultCode"))
        }
      end
    end)
    |> unwrap_transaction_result()
    |> case do
      {:ok, value} -> value
      {:error, reason} -> %{payment_id: payment_id, status: "error", reason: inspect(reason)}
    end
  end

  defp apply_status_query_to_payment!(payment, query_result, now) do
    response_payload = query_result.response_payload
    result_code = parse_result_code(Map.get(response_payload, "ResultCode"))
    result_desc = normalize_text(Map.get(response_payload, "ResultDesc")) || "STK query processed"
    payment_status = Parser.payment_status_from_result_code(result_code)

    updated_payment =
      update_payment_status_from_query!(
        payment,
        result_code,
        result_desc,
        %{
          "request_payload" => query_result.request_payload,
          "response_payload" => response_payload
        },
        now,
        payment_status
      )

    if updated_payment.status == "success" do
      Activation.activate_subscription!(updated_payment, now)
    end

    updated_payment
  end

  defp update_payment_status_from_query!(
         payment,
         result_code,
         result_desc,
         status_query_payload,
         now,
         payment_status \\ "failed"
       ) do
    payment
    |> SubscriptionPayment.create_changeset(%{
      "status" => payment_status,
      "result_code" => result_code,
      "result_desc" => result_desc,
      "status_query_payload" => status_query_payload,
      "paid_at" => if(payment_status == "success", do: now, else: nil)
    })
    |> Repo.update()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp mark_payment_timeout!(payment, now) do
    update_payment_status_from_query!(
      payment,
      1037,
      "STK callback timeout reached before webhook confirmation",
      %{"reason" => "stale_timeout_threshold_reached"},
      now,
      "timeout"
    )
  end

  defp mpesa_client_module,
    do: Application.get_env(:liddr, :mpesa_client, Client)

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp parse_result_code(value) when is_integer(value), do: value

  defp parse_result_code(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp parse_result_code(_value), do: -1

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
