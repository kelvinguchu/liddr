defmodule Liddr.Subscriptions.ReconciliationTest do
  use Liddr.DataCase, async: false

  alias Decimal, as: D
  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Payments.Mpesa.ClientBehaviour
  alias Liddr.Subscriptions
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.VerificationFixtures

  defmodule FakeReconciliationMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{
           "ResponseCode" => "0",
           "MerchantRequestID" => "mr_test",
           "CheckoutRequestID" => "ws_CO_test"
         }
       }}
    end

    @impl true
    def query_stk_status(checkout_request_id) do
      result_code =
        if String.contains?(checkout_request_id, "success"),
          do: "0",
          else: "1032"

      {:ok,
       %{
         request_payload: %{"CheckoutRequestID" => checkout_request_id},
         response_payload: %{
           "ResultCode" => result_code,
           "ResultDesc" => "STK query processed",
           "CheckoutRequestID" => checkout_request_id
         }
       }}
    end

    @impl true
    def register_c2b_urls(validation_url, confirmation_url) do
      {:ok,
       %{
         request_payload: %{
           "ValidationURL" => validation_url,
           "ConfirmationURL" => confirmation_url
         },
         response_payload: %{"ResponseDescription" => "success"}
       }}
    end

    @impl true
    def query_transaction_status(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{"ResponseCode" => "0"}
       }}
    end
  end

  defmodule SlowReconciliationMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{
           "ResponseCode" => "0",
           "MerchantRequestID" => "mr_test",
           "CheckoutRequestID" => "ws_CO_test"
         }
       }}
    end

    @impl true
    def query_stk_status(checkout_request_id) do
      test_pid = Application.get_env(:liddr, :reconciliation_test_pid)

      if is_pid(test_pid) do
        send(test_pid, {:query_started, self(), checkout_request_id})
      end

      result_code =
        receive do
          {:continue_query, value} -> value
        after
          5_000 -> 1032
        end

      {:ok,
       %{
         request_payload: %{"CheckoutRequestID" => checkout_request_id},
         response_payload: %{
           "ResultCode" => to_string(result_code),
           "ResultDesc" => "STK query processed",
           "CheckoutRequestID" => checkout_request_id
         }
       }}
    end

    @impl true
    def register_c2b_urls(validation_url, confirmation_url) do
      {:ok,
       %{
         request_payload: %{
           "ValidationURL" => validation_url,
           "ConfirmationURL" => confirmation_url
         },
         response_payload: %{"ResponseDescription" => "success"}
       }}
    end

    @impl true
    def query_transaction_status(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{"ResponseCode" => "0"}
       }}
    end
  end

  defmodule FailQueryReconciliationMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{
           "ResponseCode" => "0",
           "MerchantRequestID" => "mr_test",
           "CheckoutRequestID" => "ws_CO_test"
         }
       }}
    end

    @impl true
    def query_stk_status(_checkout_request_id), do: {:error, :mpesa_stk_query_failed}

    @impl true
    def register_c2b_urls(validation_url, confirmation_url) do
      {:ok,
       %{
         request_payload: %{
           "ValidationURL" => validation_url,
           "ConfirmationURL" => confirmation_url
         },
         response_payload: %{"ResponseDescription" => "success"}
       }}
    end

    @impl true
    def query_transaction_status(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{"ResponseCode" => "0"}
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:liddr, :mpesa_client)
    Application.put_env(:liddr, :mpesa_client, FakeReconciliationMpesaClient)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end
    end)

    :ok
  end

  test "reconcile_pending_payments marks successful query as success and activates subscription" do
    %{driver: driver, payment: payment, subscription: subscription} =
      create_pending_subscription_payment!("ws_CO_success_#{System.unique_integer([:positive])}")

    {:ok, results} =
      Subscriptions.reconcile_pending_payments(%{
        limit: 10,
        grace_seconds: 0,
        max_age_seconds: 3600
      })

    assert Enum.any?(results, fn result ->
             result.payment_id == payment.id and result.status == "success"
           end)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    updated_subscription = Repo.get!(Subscription, subscription.id)
    updated_driver = Repo.get!(Driver, driver.user_id)

    assert updated_payment.status == "success"
    assert updated_subscription.status == "active"
    assert updated_driver.subscription_status == "active"
  end

  test "reconcile_pending_payments marks stale pending callback as timeout" do
    stale_requested_at =
      DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:microsecond)

    %{payment: payment} =
      create_pending_subscription_payment!(
        "ws_CO_stale_#{System.unique_integer([:positive])}",
        stale_requested_at
      )

    {:ok, results} =
      Subscriptions.reconcile_pending_payments(%{
        limit: 10,
        grace_seconds: 0,
        max_age_seconds: 120
      })

    assert Enum.any?(results, fn result ->
             result.payment_id == payment.id and result.status == "timeout"
           end)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    assert updated_payment.status == "timeout"
  end

  test "reconcile_pending_payments does not hold row lock while querying STK status" do
    checkout_request_id = "ws_CO_query_lock_#{System.unique_integer([:positive])}"
    %{payment: payment} = create_pending_subscription_payment!(checkout_request_id)

    previous_client = Application.get_env(:liddr, :mpesa_client)
    previous_test_pid = Application.get_env(:liddr, :reconciliation_test_pid)
    Application.put_env(:liddr, :mpesa_client, SlowReconciliationMpesaClient)
    Application.put_env(:liddr, :reconciliation_test_pid, self())

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end

      if previous_test_pid do
        Application.put_env(:liddr, :reconciliation_test_pid, previous_test_pid)
      else
        Application.delete_env(:liddr, :reconciliation_test_pid)
      end
    end)

    task =
      Task.async(fn ->
        Subscriptions.reconcile_pending_payments(%{
          limit: 10,
          grace_seconds: 0,
          max_age_seconds: 3600
        })
      end)

    assert_receive {:query_started, caller_pid, ^checkout_request_id}, 1_000

    started_at_ms = System.monotonic_time(:millisecond)

    {count, _} =
      Repo.update_all(
        from(p in SubscriptionPayment, where: p.id == ^payment.id),
        set: [result_desc: "manual lock-check update"]
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert count == 1
    assert elapsed_ms < 1_000

    send(caller_pid, {:continue_query, 1032})
    {:ok, _results} = Task.await(task, 5_000)
  end

  test "reconcile_pending_payments keeps callback-finalized status when query returns later" do
    checkout_request_id = "ws_CO_query_race_#{System.unique_integer([:positive])}"
    %{payment: payment} = create_pending_subscription_payment!(checkout_request_id)

    previous_client = Application.get_env(:liddr, :mpesa_client)
    previous_test_pid = Application.get_env(:liddr, :reconciliation_test_pid)
    Application.put_env(:liddr, :mpesa_client, SlowReconciliationMpesaClient)
    Application.put_env(:liddr, :reconciliation_test_pid, self())

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end

      if previous_test_pid do
        Application.put_env(:liddr, :reconciliation_test_pid, previous_test_pid)
      else
        Application.delete_env(:liddr, :reconciliation_test_pid)
      end
    end)

    task =
      Task.async(fn ->
        Subscriptions.reconcile_pending_payments(%{
          limit: 10,
          grace_seconds: 0,
          max_age_seconds: 3600
        })
      end)

    assert_receive {:query_started, caller_pid, ^checkout_request_id}, 1_000

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    payment
    |> SubscriptionPayment.create_changeset(%{
      "status" => "cancelled",
      "result_code" => 1032,
      "result_desc" => "Request Cancelled by user.",
      "callback_received_at" => now
    })
    |> Repo.update!()

    send(caller_pid, {:continue_query, 0})

    {:ok, results} = Task.await(task, 5_000)

    assert Enum.any?(results, fn result ->
             result.payment_id == payment.id and result.status == "already_final"
           end)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    assert updated_payment.status == "cancelled"
    assert updated_payment.result_code == 1032
  end

  test "reconcile_pending_payments fails fast when checkout request id is missing" do
    %{payment: payment} = create_pending_subscription_payment!(nil)

    {:ok, results} =
      Subscriptions.reconcile_pending_payments(%{
        limit: 10,
        grace_seconds: 0,
        max_age_seconds: 3600
      })

    assert Enum.any?(results, fn result ->
             result.payment_id == payment.id and result.status == "failed"
           end)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    assert updated_payment.status == "failed"
    assert updated_payment.result_code == -1
  end

  test "reconcile_pending_payments reports query failure without mutating pending status" do
    checkout_request_id = "ws_CO_fail_#{System.unique_integer([:positive])}"
    %{payment: payment} = create_pending_subscription_payment!(checkout_request_id)
    previous_client = Application.get_env(:liddr, :mpesa_client)
    Application.put_env(:liddr, :mpesa_client, FailQueryReconciliationMpesaClient)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end
    end)

    {:ok, results} =
      Subscriptions.reconcile_pending_payments(%{
        limit: 10,
        grace_seconds: 0,
        max_age_seconds: 3600
      })

    assert Enum.any?(results, fn result ->
             result.payment_id == payment.id and result.status == "query_failed"
           end)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    assert updated_payment.status == "pending_callback"
  end

  defp create_pending_subscription_payment!(checkout_request_id, requested_at \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "inactive"
      )

    week_start = Date.beginning_of_week(Date.utc_today(), :monday)
    week_end = Date.add(week_start, 6)

    subscription =
      %Subscription{}
      |> Subscription.create_changeset(%{
        "driver_id" => driver.user_id,
        "vehicle_category_id" => category_id,
        "week_start" => week_start,
        "week_end" => week_end,
        "amount_kes" => D.new("1000.00"),
        "status" => "pending"
      })
      |> Repo.insert!()

    payment =
      %SubscriptionPayment{}
      |> SubscriptionPayment.create_changeset(%{
        "subscription_id" => subscription.id,
        "driver_id" => driver.user_id,
        "provider" => "mpesa",
        "payment_channel" => "stk_push",
        "status" => "pending_callback",
        "amount_kes" => D.new("1000.00"),
        "currency" => "KES",
        "phone_e164" => "254725799783",
        "merchant_request_id" => "mr_#{System.unique_integer([:positive])}",
        "checkout_request_id" => checkout_request_id,
        "requested_at" => requested_at || now,
        "request_payload" => %{"seed" => true}
      })
      |> Repo.insert!()

    %{driver: driver, subscription: subscription, payment: payment}
  end
end
