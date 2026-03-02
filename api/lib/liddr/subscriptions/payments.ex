defmodule Liddr.Subscriptions.Payments do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Payments.Mpesa.Client
  alias Liddr.Repo
  alias Liddr.Subscriptions.MpesaCallback
  alias Liddr.Subscriptions.PaymentUtils
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment

  @active_subscription_statuses ~w(active grace)
  @mutable_subscription_statuses ~w(pending expired cancelled)
  @pending_payment_statuses ~w(initiated pending_callback)

  def initiate_payment(driver_user_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {week_start, week_end} = current_week_range(Date.utc_today())

    with {:ok, prepared} <-
           prepare_payment_attempt(driver_user_id, attrs, now, week_start, week_end),
         {:ok, mpesa_result} <- request_stk_push(prepared),
         {:ok, payment} <- persist_stk_result(prepared.payment, mpesa_result) do
      {:ok,
       %{
         subscription: prepared.subscription,
         payment: payment,
         callback_url: prepared.callback_url
       }}
    else
      {:error, reason, prepared} ->
        _ = mark_payment_failed(prepared.payment, reason)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def register_c2b_urls do
    with {:ok, %{validation_url: validation_url, confirmation_url: confirmation_url}} <-
           MpesaCallback.c2b_callback_urls(),
         {:ok, result} <-
           mpesa_client_module().register_c2b_urls(validation_url, confirmation_url) do
      {:ok, %{validation_url: validation_url, confirmation_url: confirmation_url, result: result}}
    end
  end

  defp prepare_payment_attempt(driver_user_id, attrs, now, week_start, week_end) do
    Repo.transaction(fn ->
      driver = Repo.get(Driver, driver_user_id) || Repo.rollback(:driver_profile_not_found)
      user = Repo.get(User, driver_user_id) || Repo.rollback(:user_not_found)
      category = fetch_vehicle_category!(driver.vehicle_category_id)
      phone = resolve_phone!(attrs, user.phone)
      callback_url = callback_url!()

      subscription = get_or_create_subscription!(driver, category, week_start, week_end)

      if subscription.status in @active_subscription_statuses do
        Repo.rollback(:subscription_already_active)
      end

      ensure_no_pending_payment!(subscription.id)

      payment =
        create_initiated_payment!(%{
          subscription_id: subscription.id,
          driver_id: driver.user_id,
          amount_kes: category.weekly_sub_kes,
          phone: phone,
          requested_at: now
        })

      %{
        subscription: subscription,
        payment: payment,
        callback_url: callback_url,
        amount_kes: category.weekly_sub_kes,
        phone: phone
      }
    end)
    |> unwrap_transaction_result()
  end

  defp request_stk_push(prepared) do
    case mpesa_client_module().initiate_stk_push(%{
           amount: prepared.amount_kes,
           phone: prepared.phone,
           callback_url: prepared.callback_url,
           account_reference: "LIDDR-SUB-#{prepared.subscription.id}",
           transaction_desc: "Liddr weekly subscription"
         }) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason, prepared}
    end
  end

  defp persist_stk_result(payment, mpesa_result) do
    response_payload = mpesa_result.response_payload
    response_code = PaymentUtils.parse_integer(Map.get(response_payload, "ResponseCode"), -1)
    payment_status = if response_code == 0, do: "pending_callback", else: "failed"

    payment
    |> SubscriptionPayment.create_changeset(%{
      "status" => payment_status,
      "merchant_request_id" =>
        PaymentUtils.normalize_text(Map.get(response_payload, "MerchantRequestID")),
      "checkout_request_id" =>
        PaymentUtils.normalize_text(Map.get(response_payload, "CheckoutRequestID")),
      "result_code" => response_code,
      "result_desc" =>
        PaymentUtils.normalize_text(Map.get(response_payload, "ResponseDescription")),
      "request_payload" => mpesa_result.request_payload
    })
    |> Repo.update()
  end

  defp mark_payment_failed(payment, reason) do
    payment
    |> SubscriptionPayment.create_changeset(%{
      "status" => "failed",
      "result_desc" => PaymentUtils.reason_message(reason)
    })
    |> Repo.update()
  end

  defp create_initiated_payment!(attrs) do
    %SubscriptionPayment{}
    |> SubscriptionPayment.create_changeset(%{
      "subscription_id" => attrs.subscription_id,
      "driver_id" => attrs.driver_id,
      "provider" => "mpesa",
      "payment_channel" => "stk_push",
      "status" => "initiated",
      "amount_kes" => D.new(attrs.amount_kes),
      "currency" => "KES",
      "phone_e164" => attrs.phone,
      "requested_at" => attrs.requested_at,
      "result_desc" => "STK request initiated",
      "request_payload" => %{}
    })
    |> Repo.insert()
    |> case do
      {:ok, value} -> value
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp get_or_create_subscription!(driver, category, week_start, week_end) do
    existing =
      Repo.one(
        from s in Subscription,
          where:
            s.driver_id == ^driver.user_id and
              s.week_start == ^week_start and
              s.week_end == ^week_end,
          lock: "FOR UPDATE"
      )

    if existing do
      sync_existing_subscription!(existing, category)
    else
      %Subscription{}
      |> Subscription.create_changeset(%{
        "driver_id" => driver.user_id,
        "vehicle_category_id" => category.id,
        "week_start" => week_start,
        "week_end" => week_end,
        "amount_kes" => D.new(category.weekly_sub_kes),
        "status" => "pending",
        "activated_at" => nil,
        "expired_at" => nil
      })
      |> Repo.insert()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end
  end

  defp sync_existing_subscription!(subscription, category) do
    category_amount = D.new(category.weekly_sub_kes)

    should_sync? =
      subscription.status in @mutable_subscription_statuses and
        (subscription.vehicle_category_id != category.id or
           not D.eq?(subscription.amount_kes, category_amount))

    if should_sync? do
      subscription
      |> Subscription.create_changeset(%{
        "vehicle_category_id" => category.id,
        "amount_kes" => category_amount
      })
      |> Repo.update()
      |> case do
        {:ok, value} -> value
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      subscription
    end
  end

  defp ensure_no_pending_payment!(subscription_id) do
    pending =
      Repo.one(
        from p in SubscriptionPayment,
          where: p.subscription_id == ^subscription_id and p.status in ^@pending_payment_statuses,
          order_by: [desc: p.inserted_at],
          limit: 1
      )

    if pending, do: Repo.rollback(:payment_already_pending), else: :ok
  end

  defp callback_url! do
    case MpesaCallback.stk_callback_url() do
      {:ok, url} -> url
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve_phone!(attrs, fallback_phone) do
    raw_phone =
      PaymentUtils.normalize_text(
        PaymentUtils.get_value(attrs, :phone_e164) || PaymentUtils.get_value(attrs, :phone) ||
          fallback_phone
      )

    if is_nil(raw_phone) do
      Repo.rollback(:driver_phone_missing)
    end

    case Liddr.Auth.normalize_identifier_for_method("phone_otp", raw_phone) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> Repo.rollback(:invalid_mpesa_phone)
    end
  end

  defp fetch_vehicle_category!(vehicle_category_id) do
    category =
      Repo.one(
        from vc in "vehicle_categories",
          where: vc.id == ^vehicle_category_id and vc.is_active == true,
          select: %{
            id: vc.id,
            slug: vc.slug,
            label: vc.label,
            weekly_sub_kes: vc.weekly_sub_kes
          }
      )

    if category, do: category, else: Repo.rollback(:vehicle_category_not_found)
  end

  defp current_week_range(date) do
    week_start = Date.beginning_of_week(date, :monday)
    {week_start, Date.add(week_start, 6)}
  end

  defp mpesa_client_module,
    do: Application.get_env(:liddr, :mpesa_client, Client)

  defp unwrap_transaction_result({:ok, value}), do: {:ok, value}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
