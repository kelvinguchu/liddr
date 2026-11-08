defmodule LiddrWeb.SubscriptionControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Payments.Mpesa.ClientBehaviour
  alias Liddr.Repo
  alias Liddr.Subscriptions.Subscription
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  @test_phone "254725799783"

  defmodule FakeMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(input) do
      phone = Map.get(input, :phone) || Map.get(input, "phone")
      amount = Map.get(input, :amount) || Map.get(input, "amount")
      callback_url = Map.get(input, :callback_url) || Map.get(input, "callback_url")
      suffix = System.unique_integer([:positive])

      {:ok,
       %{
         request_payload: %{
           "PhoneNumber" => phone,
           "Amount" => amount,
           "CallBackURL" => callback_url
         },
         response_payload: %{
           "ResponseCode" => "0",
           "ResponseDescription" => "Success. Request accepted for processing",
           "MerchantRequestID" => "mr_#{suffix}",
           "CheckoutRequestID" => "ws_CO_#{suffix}"
         }
       }}
    end

    @impl true
    def query_stk_status(_checkout_request_id) do
      {:ok,
       %{
         request_payload: %{"CheckoutRequestID" => "ws_CO_query"},
         response_payload: %{
           "ResultCode" => "1032",
           "ResultDesc" => "Request cancelled by user"
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

  defmodule FakeFailMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(_input), do: {:error, :mpesa_stk_request_failed}

    @impl true
    def query_stk_status(_checkout_request_id), do: {:error, :mpesa_stk_query_failed}

    @impl true
    def register_c2b_urls(_validation_url, _confirmation_url),
      do: {:error, :mpesa_c2b_register_failed}

    @impl true
    def query_transaction_status(_input), do: {:error, :mpesa_transaction_status_query_failed}
  end

  setup do
    previous_client = Application.get_env(:liddr, :mpesa_client)
    previous_callback_base = System.get_env("MPESA_CALLBACK_BASE_URL")
    previous_callback_token = System.get_env("MPESA_CALLBACK_TOKEN")

    Application.put_env(:liddr, :mpesa_client, FakeMpesaClient)
    System.put_env("MPESA_CALLBACK_BASE_URL", "https://liddr-test.example.com")
    System.put_env("MPESA_CALLBACK_TOKEN", "subscription-test-token")

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end

      restore_env("MPESA_CALLBACK_BASE_URL", previous_callback_base)
      restore_env("MPESA_CALLBACK_TOKEN", previous_callback_token)
    end)

    :ok
  end

  test "POST /api/subscriptions/pay forbids non-driver roles", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)

    conn =
      post(auth_conn, "/api/subscriptions/pay", %{
        "phone" => @test_phone
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/subscriptions/pay creates pending callback payment for driver", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})

    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
      )

    conn =
      post(auth_conn, "/api/subscriptions/pay", %{
        "phone" => @test_phone
      })

    assert %{
             "data" => %{
               "subscription" => %{
                 "driver_id" => ^user_id,
                 "status" => "pending"
               },
               "payment" => %{
                 "status" => "pending_callback",
                 "phone_e164" => @test_phone,
                 "checkout_request_id" => checkout_request_id
               }
             }
           } = json_response(conn, 201)

    assert is_binary(checkout_request_id)
    assert Repo.aggregate(SubscriptionPayment, :count, :id) == 1
  end

  test "POST /api/subscriptions/pay syncs existing pending subscription amount to category price",
       %{
         conn: conn
       } do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 20})
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
      )

    week_start = Date.beginning_of_week(Date.utc_today(), :monday)
    week_end = Date.add(week_start, 6)

    existing_subscription =
      %Subscription{}
      |> Subscription.create_changeset(%{
        "driver_id" => user_id,
        "vehicle_category_id" => category_id,
        "week_start" => week_start,
        "week_end" => week_end,
        "amount_kes" => D.new(1000),
        "status" => "pending"
      })
      |> Repo.insert!()

    conn = post(auth_conn, "/api/subscriptions/pay", %{"phone" => @test_phone})

    assert %{
             "data" => %{
               "subscription" => %{"id" => subscription_id},
               "payment" => %{"status" => "pending_callback"}
             }
           } = json_response(conn, 201)

    assert subscription_id == existing_subscription.id

    persisted_subscription = Repo.get!(Subscription, existing_subscription.id)
    assert D.eq?(persisted_subscription.amount_kes, D.new(20))
  end

  test "GET /api/subscriptions/me and /api/subscriptions/me/history return driver payment state",
       %{
         conn: conn
       } do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1400})
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
      )

    _ =
      post(auth_conn, "/api/subscriptions/pay", %{
        "phone" => @test_phone
      })

    current_conn = get(auth_conn, "/api/subscriptions/me")
    history_conn = get(auth_conn, "/api/subscriptions/me/history")

    assert %{
             "data" => %{
               "driver" => %{"user_id" => ^user_id, "subscription_status" => "inactive"},
               "subscription" => %{"status" => "pending"},
               "latest_payment" => %{"status" => "pending_callback"}
             }
           } = json_response(current_conn, 200)

    assert %{"data" => %{"payments" => [first | _]}} = json_response(history_conn, 200)
    assert first["status"] == "pending_callback"
    assert first["phone_e164"] == @test_phone
  end

  test "POST /api/subscriptions/pay persists failed payment when STK push fails", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
      )

    previous_client = Application.get_env(:liddr, :mpesa_client)
    Application.put_env(:liddr, :mpesa_client, FakeFailMpesaClient)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:liddr, :mpesa_client, previous_client)
      else
        Application.delete_env(:liddr, :mpesa_client)
      end
    end)

    conn =
      post(auth_conn, "/api/subscriptions/pay", %{
        "phone" => @test_phone
      })

    assert %{"error" => %{"code" => "MPESA_STK_REQUEST_FAILED"}} = json_response(conn, 503)

    failed_payment =
      Repo.one!(
        from p in SubscriptionPayment,
          where: p.driver_id == ^user_id,
          order_by: [desc: p.inserted_at],
          limit: 1
      )

    assert failed_payment.status == "failed"
    assert failed_payment.phone_e164 == @test_phone
  end

  test "POST /api/subscriptions/pay returns 503 when callback token config is missing", %{
    conn: conn
  } do
    System.delete_env("MPESA_CALLBACK_TOKEN")
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.get!(User, user_id)

    _driver =
      VerificationFixtures.create_driver!(
        user: user,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved"
      )

    conn =
      post(auth_conn, "/api/subscriptions/pay", %{
        "phone" => @test_phone
      })

    assert %{"error" => %{"code" => "MISSING_CALLBACK_TOKEN_CONFIG"}} = json_response(conn, 503)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
