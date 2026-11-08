defmodule LiddrWeb.SubscriptionOpsIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Payments.Mpesa.ClientBehaviour
  alias Liddr.Repo
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  defmodule FakeUniqueOpsMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input), do: {:error, :not_used}

    @impl true
    def query_stk_status(_checkout_request_id), do: {:error, :not_used}

    @impl true
    def register_c2b_urls(validation_url, confirmation_url) do
      nonce = System.unique_integer([:positive])

      {:ok,
       %{
         request_payload: %{
           "ValidationURL" => validation_url,
           "ConfirmationURL" => confirmation_url
         },
         response_payload: %{
           "ResponseDescription" => "success",
           "Nonce" => "register-#{nonce}"
         }
       }}
    end

    @impl true
    def query_transaction_status(_input) do
      nonce = System.unique_integer([:positive])

      {:ok,
       %{
         request_payload: %{},
         response_payload: %{
           "ResponseCode" => "0",
           "ConversationID" => "AG_#{nonce}"
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
    previous_security_credential = System.get_env("MPESA_SECURITY_CREDENTIAL")
    previous_initiator = System.get_env("MPESA_INITIATOR_NAME")

    Application.put_env(:liddr, :mpesa_client, FakeUniqueOpsMpesaClient)
    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")
    System.put_env("MPESA_CALLBACK_BASE_URL", "https://api.example.com")
    System.put_env("MPESA_CALLBACK_TOKEN", "ops-callback-token")
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "query_or_header")
    System.put_env("MPESA_SECURITY_CREDENTIAL", "test-security-credential")
    System.put_env("MPESA_INITIATOR_NAME", "testapi")

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
      restore_env("MPESA_SECURITY_CREDENTIAL", previous_security_credential)
      restore_env("MPESA_INITIATOR_NAME", previous_initiator)
    end)

    :ok
  end

  test "POST /api/ops/mpesa/c2b/register-urls replays identical response for idempotency key", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-sub-idem-register@example.com")
    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    key = "ops-sub-register-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/mpesa/c2b/register-urls", %{})
      |> json_response(200)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/mpesa/c2b/register-urls", %{})
      |> json_response(200)

    assert first == second
  end

  test "POST /api/ops/mpesa/payments/checkout/:checkout_request_id/query-tx-status replays", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-sub-idem-query@example.com")
    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    %{payment: payment} = create_pending_subscription_payment!()
    key = "ops-sub-query-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post(
        "/api/ops/mpesa/payments/checkout/#{payment.checkout_request_id}/query-tx-status",
        %{}
      )
      |> json_response(200)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post(
        "/api/ops/mpesa/payments/checkout/#{payment.checkout_request_id}/query-tx-status",
        %{}
      )
      |> json_response(200)

    assert first == second
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
        "transaction_id" => "TX_#{System.unique_integer([:positive])}",
        "requested_at" => now,
        "request_payload" => %{"seed" => true}
      })
      |> Repo.insert!()

    %{driver: driver, subscription: subscription, payment: payment}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
