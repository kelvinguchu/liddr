defmodule LiddrWeb.SubscriptionIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Payments.Mpesa.ClientBehaviour
  alias Liddr.Repo
  alias Liddr.Subscriptions.SubscriptionPayment
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  @test_phone "254725799783"

  defmodule FakeMpesaClient do
    @behaviour ClientBehaviour

    @impl true
    def initiate_stk_push(input) do
      suffix = System.unique_integer([:positive])
      phone = Map.get(input, :phone) || Map.get(input, "phone")

      {:ok,
       %{
         request_payload: %{"PhoneNumber" => phone},
         response_payload: %{
           "ResponseCode" => "0",
           "ResponseDescription" => "Success. Request accepted for processing",
           "MerchantRequestID" => "mr_#{suffix}",
           "CheckoutRequestID" => "ws_CO_#{suffix}"
         }
       }}
    end

    @impl true
    def query_stk_status(_checkout_request_id), do: {:error, :not_used}

    @impl true
    def register_c2b_urls(_validation_url, _confirmation_url), do: {:error, :not_used}

    @impl true
    def query_transaction_status(_input), do: {:error, :not_used}
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

  test "POST /api/subscriptions/pay replays response for identical idempotency key", %{
    conn: conn
  } do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.get!(User, user_id)
    _driver = create_driver_profile!(user, category_id)

    key = "sub-pay-#{System.unique_integer([:positive])}"

    first =
      auth_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/subscriptions/pay", %{"phone" => @test_phone})
      |> json_response(201)

    second =
      auth_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/subscriptions/pay", %{"phone" => @test_phone})
      |> json_response(201)

    first_payment = get_in(first, ["data", "payment"])
    second_payment = get_in(second, ["data", "payment"])

    assert first_payment["id"] == second_payment["id"]
    assert first_payment["checkout_request_id"] == second_payment["checkout_request_id"]

    count =
      Repo.one!(
        from p in SubscriptionPayment,
          where: p.driver_id == ^user_id,
          select: count(p.id)
      )

    assert count == 1
  end

  test "POST /api/subscriptions/pay rejects idempotency key reuse with different payload", %{
    conn: conn
  } do
    %{auth_conn: auth_conn, user_id: user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!(%{weekly_sub_kes: 1000})
    user = Repo.get!(User, user_id)
    _driver = create_driver_profile!(user, category_id)

    key = "sub-pay-mismatch-#{System.unique_integer([:positive])}"

    _ =
      auth_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/subscriptions/pay", %{"phone" => @test_phone})
      |> json_response(201)

    assert %{"error" => %{"code" => "IDEMPOTENCY_KEY_REUSED"}} =
             auth_conn
             |> recycle()
             |> put_req_header("idempotency-key", key)
             |> post("/api/subscriptions/pay", %{"phone" => "254700000001"})
             |> json_response(409)
  end

  defp create_driver_profile!(user, category_id) do
    VerificationFixtures.create_driver!(
      user: user,
      vehicle_category_id: category_id,
      account_status: "active",
      verification_status: "approved"
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
