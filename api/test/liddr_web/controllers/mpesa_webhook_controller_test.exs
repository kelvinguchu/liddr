defmodule LiddrWeb.MpesaWebhookControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.Subscriptions.WebhookEvent
  alias Liddr.VerificationFixtures

  @callback_token "mpesa-callback-token"
  @callback_phone "254725799783"

  setup do
    previous_callback_token = System.get_env("MPESA_CALLBACK_TOKEN")
    previous_callback_transport = System.get_env("MPESA_CALLBACK_TOKEN_TRANSPORT")
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ip_allowlist = System.get_env("MPESA_CALLBACK_IP_ALLOWLIST")
    previous_trust_proxy_headers = System.get_env("SECURITY_TRUST_PROXY_HEADERS")

    System.put_env("MPESA_CALLBACK_TOKEN", @callback_token)
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "query_or_header")
    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("MPESA_CALLBACK_IP_ALLOWLIST")
    System.put_env("SECURITY_TRUST_PROXY_HEADERS", "false")

    on_exit(fn ->
      restore_env("MPESA_CALLBACK_TOKEN", previous_callback_token)
      restore_env("MPESA_CALLBACK_TOKEN_TRANSPORT", previous_callback_transport)
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("MPESA_CALLBACK_IP_ALLOWLIST", previous_ip_allowlist)
      restore_env("SECURITY_TRUST_PROXY_HEADERS", previous_trust_proxy_headers)
    end)

    :ok
  end

  test "POST /api/payments/mpesa/stk-callback processes callback and activates subscription", %{
    conn: conn
  } do
    %{driver: driver, subscription: subscription, payment: payment} =
      create_pending_subscription_payment!()

    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    updated_subscription = Repo.get!(Subscription, subscription.id)
    updated_driver = Repo.get!(Liddr.Accounts.Driver, driver.user_id)

    assert updated_payment.status == "success"
    assert updated_payment.result_code == 0
    assert updated_payment.mpesa_receipt_number == "QWERTY1234"
    assert updated_payment.phone_e164 == @callback_phone
    assert not is_nil(updated_payment.paid_at)

    assert updated_subscription.status == "active"
    assert updated_driver.subscription_status == "active"

    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/stk-callback is idempotent for duplicate callbacks", %{
    conn: conn
  } do
    %{payment: payment} = create_pending_subscription_payment!()

    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    first_conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    second_conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0} = json_response(first_conn, 200)
    assert %{"ResultCode" => 0} = json_response(second_conn, 200)
    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/stk-callback rejects success callbacks with mismatched amount",
       %{
         conn: conn
       } do
    %{payment: payment} = create_pending_subscription_payment!()

    payload =
      stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0, %{
        amount: 123
      })

    conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"error" => %{"code" => "CALLBACK_AMOUNT_MISMATCH"}} = json_response(conn, 422)
  end

  test "POST /api/payments/mpesa/stk-callback rejects success callbacks with mismatched phone", %{
    conn: conn
  } do
    %{payment: payment} = create_pending_subscription_payment!()

    payload =
      stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0, %{
        phone: "254700000000"
      })

    conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"error" => %{"code" => "CALLBACK_PHONE_MISMATCH"}} = json_response(conn, 422)
  end

  test "POST /api/payments/mpesa/stk-callback accepts unknown checkout request id for reconciliation",
       %{
         conn: conn
       } do
    %{payment: payment} = create_pending_subscription_payment!()

    payload =
      stk_callback_payload(
        payment.checkout_request_id <> "_unknown",
        payment.merchant_request_id,
        0
      )

    conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)
  end

  test "POST /api/payments/mpesa/stk-callback supports header callback token in header-only mode",
       %{
         conn: conn
       } do
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "header")
    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn =
      conn
      |> put_req_header("x-mpesa-callback-token", @callback_token)
      |> post("/api/payments/mpesa/stk-callback", payload)

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)
  end

  test "POST /api/payments/mpesa/stk-callback rejects query callback token in header-only mode",
       %{
         conn: conn
       } do
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "header")
    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn =
      post(
        conn,
        "/api/payments/mpesa/stk-callback?token=#{@callback_token}",
        payload
      )

    assert %{"error" => %{"code" => "INVALID_CALLBACK_TOKEN"}} = json_response(conn, 401)
  end

  test "POST /api/payments/mpesa/stk-callback enforces IP allowlist in enforce mode", %{
    conn: conn
  } do
    System.put_env("SECURITY_MODE", "enforce")
    System.put_env("MPESA_CALLBACK_IP_ALLOWLIST", "203.0.113.10/32")

    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn =
      conn
      |> with_remote_ip({127, 0, 0, 1})
      |> post("/api/payments/mpesa/stk-callback?token=#{@callback_token}", payload)

    assert %{"error" => %{"code" => "IP_NOT_ALLOWED"}} = json_response(conn, 403)
  end

  test "POST /api/payments/mpesa/stk-callback observes IP allowlist without blocking in observe mode",
       %{
         conn: conn
       } do
    System.put_env("SECURITY_MODE", "observe")
    System.put_env("MPESA_CALLBACK_IP_ALLOWLIST", "203.0.113.10/32")

    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn =
      conn
      |> with_remote_ip({127, 0, 0, 1})
      |> post("/api/payments/mpesa/stk-callback?token=#{@callback_token}", payload)

    assert %{"ResultCode" => 0} = json_response(conn, 200)
  end

  test "POST /api/payments/mpesa/stk-callback remains idempotent under concurrent duplicate callbacks",
       %{
         conn: _conn
       } do
    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    responses =
      Task.async_stream(
        1..5,
        fn _ ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/payments/mpesa/stk-callback?token=#{@callback_token}", payload)
          |> json_response(200)
        end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.all?(responses, &(&1["ResultCode"] == 0))
    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/stk-callback rejects invalid callback token", %{conn: conn} do
    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn = post(conn, "/api/payments/mpesa/stk-callback", payload)

    assert %{"error" => %{"code" => "INVALID_CALLBACK_TOKEN"}} = json_response(conn, 401)
  end

  test "POST /api/payments/mpesa/stk-callback fails closed when callback token config is missing",
       %{conn: conn} do
    System.delete_env("MPESA_CALLBACK_TOKEN")

    %{payment: payment} = create_pending_subscription_payment!()
    payload = stk_callback_payload(payment.checkout_request_id, payment.merchant_request_id, 0)

    conn = post(conn, "/api/payments/mpesa/stk-callback?token=#{@callback_token}", payload)

    assert %{"error" => %{"code" => "MISSING_CALLBACK_TOKEN_CONFIG"}} = json_response(conn, 503)
  end

  test "POST /api/payments/mpesa/c2b-validation accepts valid callback token", %{conn: conn} do
    conn = post(conn, "/api/payments/mpesa/c2b-validation?token=#{@callback_token}", %{})
    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)
  end

  test "POST /api/payments/mpesa/c2b-validation rejects invalid callback token", %{conn: conn} do
    conn = post(conn, "/api/payments/mpesa/c2b-validation", %{})
    assert %{"error" => %{"code" => "INVALID_CALLBACK_TOKEN"}} = json_response(conn, 401)
  end

  test "POST /api/payments/mpesa/c2b-confirmation processes callback and activates subscription",
       %{
         conn: conn
       } do
    %{subscription: subscription} = create_pending_subscription_payment!()
    payload = c2b_confirmation_payload(subscription.id, "SIK2W3AR4T")

    conn =
      post(
        conn,
        "/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)

    c2b_payment =
      Repo.one!(
        from p in SubscriptionPayment,
          where: p.transaction_id == "SIK2W3AR4T",
          order_by: [desc: p.inserted_at],
          limit: 1
      )

    updated_subscription = Repo.get!(Subscription, subscription.id)

    assert c2b_payment.status == "success"
    assert c2b_payment.payment_channel == "c2b"
    assert updated_subscription.status == "active"
  end

  test "POST /api/payments/mpesa/c2b-confirmation is idempotent for duplicates", %{conn: conn} do
    %{subscription: subscription} = create_pending_subscription_payment!()
    payload = c2b_confirmation_payload(subscription.id, "SIK2W3AR4D")

    first_conn =
      post(
        conn,
        "/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}",
        payload
      )

    second_conn =
      post(
        conn,
        "/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0} = json_response(first_conn, 200)
    assert %{"ResultCode" => 0} = json_response(second_conn, 200)
    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/c2b-confirmation remains idempotent under concurrent duplicates",
       %{conn: _conn} do
    %{subscription: subscription} = create_pending_subscription_payment!()
    transaction_id = "SIK2W3AR#{System.unique_integer([:positive])}"
    payload = c2b_confirmation_payload(subscription.id, transaction_id)

    responses =
      Task.async_stream(
        1..5,
        fn _ ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}", payload)
          |> json_response(200)
        end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.all?(responses, &(&1["ResultCode"] == 0))
    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/c2b-confirmation rejects invalid bill ref", %{conn: conn} do
    payload = c2b_confirmation_payload(nil, "SIK2W3AR9T")

    conn =
      post(
        conn,
        "/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}",
        payload
      )

    assert %{"error" => %{"code" => "INVALID_C2B_BILL_REF"}} = json_response(conn, 422)
  end

  test "POST /api/payments/mpesa/tx-status-callback processes callback by transaction id", %{
    conn: conn
  } do
    %{driver: driver, subscription: subscription, payment: payment} =
      create_pending_subscription_payment!(%{"transaction_id" => "SIK2W3AR4Z"})

    payload = tx_status_callback_payload("SIK2W3AR4Z", 0)

    conn =
      post(
        conn,
        "/api/payments/mpesa/tx-status-callback?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    updated_subscription = Repo.get!(Subscription, subscription.id)
    updated_driver = Repo.get!(Liddr.Accounts.Driver, driver.user_id)

    assert updated_payment.status == "success"
    assert updated_payment.transaction_id == "SIK2W3AR4Z"
    assert updated_subscription.status == "active"
    assert updated_driver.subscription_status == "active"
  end

  test "POST /api/payments/mpesa/tx-status-callback remains idempotent under concurrent duplicates",
       %{
         conn: _conn
       } do
    %{payment: payment} =
      create_pending_subscription_payment!(%{
        "transaction_id" => "SIK2W3AR#{System.unique_integer([:positive])}"
      })

    payload = tx_status_callback_payload(payment.transaction_id, 0)

    responses =
      Task.async_stream(
        1..5,
        fn _ ->
          build_conn()
          |> put_req_header("content-type", "application/json")
          |> post("/api/payments/mpesa/tx-status-callback?token=#{@callback_token}", payload)
          |> json_response(200)
        end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert Enum.all?(responses, &(&1["ResultCode"] == 0))
    assert Repo.aggregate(WebhookEvent, :count, :id) == 1
  end

  test "POST /api/payments/mpesa/tx-status-callback accepts unknown payment for reconciliation",
       %{
         conn: conn
       } do
    payload = tx_status_callback_payload("UNKNOWN_TX_1", 0)

    conn =
      post(
        conn,
        "/api/payments/mpesa/tx-status-callback?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)
  end

  test "POST /api/payments/mpesa/c2b-confirmation accepts valid unknown subscription bill ref", %{
    conn: conn
  } do
    payload = c2b_confirmation_payload(9_999_999, "SIK2W3AR9X")

    conn =
      post(
        conn,
        "/api/payments/mpesa/c2b-confirmation?token=#{@callback_token}",
        payload
      )

    assert %{"ResultCode" => 0, "ResultDesc" => "Accepted"} = json_response(conn, 200)
  end

  defp create_pending_subscription_payment!(payment_overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
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
      |> SubscriptionPayment.create_changeset(
        %{
          "subscription_id" => subscription.id,
          "driver_id" => driver.user_id,
          "provider" => "mpesa",
          "payment_channel" => "stk_push",
          "status" => "pending_callback",
          "amount_kes" => D.new("1000.00"),
          "currency" => "KES",
          "phone_e164" => @callback_phone,
          "merchant_request_id" => "mr_#{System.unique_integer([:positive])}",
          "checkout_request_id" => "ws_CO_#{System.unique_integer([:positive])}",
          "requested_at" => now,
          "request_payload" => %{"seed" => true}
        }
        |> Map.merge(payment_overrides)
      )
      |> Repo.insert!()

    %{driver: driver, subscription: subscription, payment: payment}
  end

  defp stk_callback_payload(
         checkout_request_id,
         merchant_request_id,
         result_code,
         overrides \\ %{}
       ) do
    amount = Map.get(overrides, :amount, 1000)
    phone = Map.get(overrides, :phone, @callback_phone)

    %{
      "Body" => %{
        "stkCallback" => %{
          "MerchantRequestID" => merchant_request_id,
          "CheckoutRequestID" => checkout_request_id,
          "ResultCode" => result_code,
          "ResultDesc" => "Processed",
          "CallbackMetadata" => %{
            "Item" => [
              %{"Name" => "Amount", "Value" => amount},
              %{"Name" => "MpesaReceiptNumber", "Value" => "QWERTY1234"},
              %{"Name" => "TransactionDate", "Value" => 20_260_301_220_000},
              %{"Name" => "PhoneNumber", "Value" => phone}
            ]
          }
        }
      }
    }
  end

  defp c2b_confirmation_payload(subscription_id, transaction_id) do
    %{
      "TransID" => transaction_id,
      "TransAmount" => 1000,
      "BillRefNumber" => if(subscription_id, do: "LIDDR-SUB-#{subscription_id}", else: "invalid"),
      "MSISDN" => @callback_phone,
      "FirstName" => "Jane",
      "MiddleName" => "W",
      "LastName" => "Doe",
      "TransTime" => "20260302141233"
    }
  end

  defp tx_status_callback_payload(transaction_id, result_code) do
    %{
      "Result" => %{
        "ResultType" => 0,
        "ResultCode" => result_code,
        "ResultDesc" => "Transaction status processed",
        "OriginatorConversationID" => "12345-12345-1",
        "ConversationID" => "AG_20260302_0000123",
        "TransactionID" => transaction_id
      }
    }
  end

  defp with_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
