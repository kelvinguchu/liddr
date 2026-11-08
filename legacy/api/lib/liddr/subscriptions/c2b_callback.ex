defmodule Liddr.Subscriptions.C2BCallback do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Payments.Mpesa.Parser
  alias Liddr.Payments.Mpesa.Sanitizer
  alias Liddr.Repo
  alias Liddr.Subscriptions.Activation
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.Subscriptions.WebhookEvents

  def handle(payload) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, parsed} <- Parser.parse_c2b_callback(payload) do
      external_ref = parsed.transaction_id || "payload_" <> sha256_hex(payload)

      Repo.transaction(fn ->
        event = WebhookEvents.get_or_create!("c2b_callback", external_ref, payload)

        if event.processed_at do
          %{status: :duplicate}
        else
          {subscription, driver} = find_subscription_for_c2b!(parsed.bill_ref_number)
          ensure_callback_amount_matches!(subscription.amount_kes, parsed.amount_kes)

          payment = upsert_c2b_payment!(subscription, driver, parsed, payload, now)

          if payment.status == "success" do
            Activation.activate_subscription!(payment, now)
          end

          WebhookEvents.mark_processed!(event, now)
          %{status: :processed, payment: payment}
        end
      end)
      |> unwrap_transaction_result()
    end
  end

  defp find_subscription_for_c2b!(bill_ref_number) do
    subscription_id = parse_subscription_id_from_bill_ref!(bill_ref_number)

    subscription =
      Repo.one(
        from s in Subscription,
          where: s.id == ^subscription_id,
          lock: "FOR UPDATE"
      ) || Repo.rollback(:subscription_not_found)

    driver = Repo.get(Driver, subscription.driver_id) || Repo.rollback(:driver_profile_not_found)
    {subscription, driver}
  end

  defp parse_subscription_id_from_bill_ref!(bill_ref_number) do
    bill_ref = normalize_text(bill_ref_number) || Repo.rollback(:invalid_c2b_bill_ref)

    case Regex.run(~r/^LIDDR-SUB-(\d+)$/i, bill_ref) do
      [_, id_text] ->
        parse_integer(id_text, -1)
        |> case do
          id when id > 0 -> id
          _ -> Repo.rollback(:invalid_c2b_bill_ref)
        end

      _ ->
        Repo.rollback(:invalid_c2b_bill_ref)
    end
  end

  defp ensure_callback_amount_matches!(_expected_amount, nil),
    do: Repo.rollback(:callback_amount_mismatch)

  defp ensure_callback_amount_matches!(expected_amount, parsed_amount) do
    if D.compare(expected_amount, parsed_amount) == :eq,
      do: :ok,
      else: Repo.rollback(:callback_amount_mismatch)
  end

  defp upsert_c2b_payment!(subscription, driver, parsed, payload, now) do
    existing = find_existing_payment_by_transaction_id!(parsed.transaction_id)

    attrs = %{
      "subscription_id" => subscription.id,
      "driver_id" => driver.user_id,
      "provider" => "mpesa",
      "payment_channel" => "c2b",
      "status" => "success",
      "amount_kes" => parsed.amount_kes,
      "currency" => "KES",
      "phone_e164" => parsed.phone_e164,
      "transaction_id" => parsed.transaction_id,
      "mpesa_receipt_number" => parsed.transaction_id,
      "result_code" => 0,
      "result_desc" => "C2B confirmation received",
      "requested_at" => now,
      "callback_received_at" => now,
      "paid_at" => now,
      "callback_payload" => Sanitizer.payload(payload)
    }

    if existing do
      existing
      |> SubscriptionPayment.create_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      %SubscriptionPayment{}
      |> SubscriptionPayment.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp find_existing_payment_by_transaction_id!(transaction_id) do
    Repo.one(
      from p in SubscriptionPayment,
        where: p.transaction_id == ^transaction_id,
        order_by: [desc: p.inserted_at],
        lock: "FOR UPDATE",
        limit: 1
    )
  end

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp sha256_hex(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

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

  defp parse_integer(nil, default), do: default

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_integer(value, _default) when is_integer(value), do: value
  defp parse_integer(_value, default), do: default
end
