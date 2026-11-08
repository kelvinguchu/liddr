defmodule LiddrWeb.SubscriptionOpsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Payments.Mpesa.ClientBehaviour
  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Security.Redaction
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeOpsMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{"ResponseCode" => "0"}
       }}
    end

    @impl true
    def query_stk_status(_checkout_request_id) do
      {:ok,
       %{
         request_payload: %{},
         response_payload: %{"ResultCode" => "0", "ResultDesc" => "Processed"}
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
    def query_transaction_status(input) do
      {:ok,
       %{
         request_payload: %{
           "TransactionID" => input[:transaction_id]
         },
         response_payload: %{
           "ResponseCode" => "0",
           "ResponseDescription" => "Accept the service request successfully.",
           "ConversationID" => "AG_20260302_0000999",
           "OriginatorConversationID" => "12345-67890-1"
         }
       }}
    end
  end

  setup do
    previous_client = Application.get_env(:liddr, :mpesa_client)
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")
    previous_callback_base_url = System.get_env("MPESA_CALLBACK_BASE_URL")
    previous_callback_token = System.get_env("MPESA_CALLBACK_TOKEN")
    previous_callback_transport = System.get_env("MPESA_CALLBACK_TOKEN_TRANSPORT")

    Application.put_env(:liddr, :mpesa_client, FakeOpsMpesaClient)
    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")
    System.put_env("MPESA_CALLBACK_BASE_URL", "https://api.example.com")
    System.put_env("MPESA_CALLBACK_TOKEN", "ops-callback-token")
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "query_or_header")

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end

      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
      restore_env("MPESA_CALLBACK_BASE_URL", previous_callback_base_url)
      restore_env("MPESA_CALLBACK_TOKEN", previous_callback_token)
      restore_env("MPESA_CALLBACK_TOKEN_TRANSPORT", previous_callback_transport)
    end)

    :ok
  end

  test "GET /api/ops/subscriptions/drivers/:driver_user_id returns driver snapshot and payments",
       %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-subscriptions@example.com")
    %{driver: driver, payment: payment} = create_pending_subscription_payment!()

    conn = get(auth_conn, "/api/ops/subscriptions/drivers/#{driver.user_id}")

    assert %{
             "data" => %{
               "driver" => %{"user_id" => driver_user_id},
               "payments" => [
                 %{"id" => payment_id, "checkout_request_id" => checkout_request_id} | _
               ]
             }
           } = json_response(conn, 200)

    assert driver_user_id == driver.user_id
    assert payment_id == payment.id
    assert checkout_request_id == payment.checkout_request_id

    payment_row = json_response(conn, 200)["data"]["payments"] |> hd()
    assert payment_row["phone_e164_masked"] == Redaction.mask_phone(payment.phone_e164)

    assert payment_row["merchant_request_id_masked"] ==
             Redaction.mask_reference(payment.merchant_request_id)

    assert payment_row["mpesa_receipt_number_masked"] ==
             Redaction.mask_reference(payment.mpesa_receipt_number)

    assert Map.has_key?(payment_row, "transaction_id_masked")
    refute Map.has_key?(payment_row, "phone_e164")
    refute Map.has_key?(payment_row, "merchant_request_id")
    refute Map.has_key?(payment_row, "mpesa_receipt_number")
    refute Map.has_key?(payment_row, "transaction_id")
  end

  test "GET /api/ops/subscriptions/payments/checkout/:checkout_request_id returns payment details",
       %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-payments@example.com")
    %{payment: payment} = create_pending_subscription_payment!()

    conn =
      get(auth_conn, "/api/ops/subscriptions/payments/checkout/#{payment.checkout_request_id}")

    assert %{
             "data" => %{
               "payment" => %{
                 "id" => payment_id,
                 "checkout_request_id" => checkout_request_id,
                 "status" => "pending_callback"
               }
             }
           } = json_response(conn, 200)

    assert payment_id == payment.id
    assert checkout_request_id == payment.checkout_request_id
  end

  test "ops endpoints enforce IP allowlist in enforce mode", %{conn: _conn} do
    System.put_env("SECURITY_MODE", "enforce")
    System.put_env("OPS_IP_ALLOWLIST", "203.0.113.10/32")

    %{auth_conn: auth_conn} =
      AuthFixtures.authenticate_ops!("ops-ip-enforce@example.com", enroll_totp: false)

    %{driver: driver} = create_pending_subscription_payment!()

    conn =
      auth_conn
      |> with_remote_ip({127, 0, 0, 1})
      |> get("/api/ops/subscriptions/drivers/#{driver.user_id}")

    assert %{"error" => %{"code" => "IP_NOT_ALLOWED"}} = json_response(conn, 403)
  end

  test "POST /api/ops/mpesa/c2b/register-urls registers c2b callback urls", %{conn: _conn} do
    auth_conn =
      AuthFixtures.authenticate_ops!("ops-register-c2b@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    conn = post(auth_conn, "/api/ops/mpesa/c2b/register-urls", %{})

    assert %{
             "data" => %{
               "validation_url" => validation_url,
               "confirmation_url" => confirmation_url,
               "response_payload" => %{"ResponseDescription" => "success"}
             }
           } = json_response(conn, 200)

    assert String.starts_with?(
             validation_url,
             "https://api.example.com/api/payments/c2b-validation"
           )

    assert String.starts_with?(
             confirmation_url,
             "https://api.example.com/api/payments/c2b-confirmation"
           )
  end

  test "POST /api/ops/mpesa/payments/checkout/:checkout_request_id/query-tx-status updates query payload",
       %{conn: _conn} do
    auth_conn =
      AuthFixtures.authenticate_ops!("ops-query-tx-status@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    %{payment: payment} = create_pending_subscription_payment!()

    conn =
      post(
        auth_conn,
        "/api/ops/mpesa/payments/checkout/#{payment.checkout_request_id}/query-tx-status",
        %{}
      )

    assert %{
             "data" => %{
               "payment" => %{"id" => payment_id},
               "response_payload" => %{"ResponseCode" => "0"}
             }
           } = json_response(conn, 200)

    assert payment_id == payment.id

    updated_payment = Repo.get!(SubscriptionPayment, payment.id)
    assert updated_payment.conversation_id == "AG_20260302_0000999"
    assert updated_payment.originator_conversation_id == "12345-67890-1"
    assert is_map(updated_payment.status_query_payload)
  end

  test "POST /api/ops/mpesa/c2b/register-urls returns 503 when callback token config is missing",
       %{conn: _conn} do
    System.delete_env("MPESA_CALLBACK_TOKEN")

    auth_conn =
      AuthFixtures.authenticate_ops!("ops-missing-callback-token@example.com")
      |> Map.fetch!(:auth_conn)
      |> AuthFixtures.with_step_up!()

    conn = post(auth_conn, "/api/ops/mpesa/c2b/register-urls", %{})

    assert %{"error" => %{"code" => "MISSING_CALLBACK_TOKEN_CONFIG"}} = json_response(conn, 503)
  end

  defp create_pending_subscription_payment! do
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
        "checkout_request_id" => "ws_CO_#{System.unique_integer([:positive])}",
        "mpesa_receipt_number" => "QWERTY#{System.unique_integer([:positive])}",
        "requested_at" => now,
        "request_payload" => %{"seed" => true}
      })
      |> Repo.insert!()

    %{driver: driver, subscription: subscription, payment: payment}
  end

  defp with_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
