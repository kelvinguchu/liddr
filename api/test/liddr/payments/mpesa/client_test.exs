defmodule Liddr.Payments.Mpesa.ClientTest do
  use ExUnit.Case, async: false

  alias Liddr.Payments.Mpesa.Client
  alias Liddr.TestSupport.MpesaStubPlug

  @env_keys ~w(
    MPESA_CONSUMER_KEY
    MPESA_CONSUMER_SECRET
    MPESA_SHORTCODE
    MPESA_PASSKEY
    MPESA_BASE_URL
  )

  setup do
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous_env, &restore_env/1) end)

    server =
      start_supervised!(
        {Bandit, plug: MpesaStubPlug, scheme: :http, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    System.put_env("MPESA_CONSUMER_KEY", "stub-key")
    System.put_env("MPESA_CONSUMER_SECRET", "stub-secret")
    System.put_env("MPESA_SHORTCODE", "174379")
    System.put_env("MPESA_PASSKEY", "stub-passkey")
    System.put_env("MPESA_BASE_URL", "http://127.0.0.1:#{port}")

    :ok
  end

  test "initiate_stk_push keeps real callback IDs and redacts the request" do
    assert {:ok, %{request_payload: request_payload, response_payload: response_payload}} =
             Client.initiate_stk_push(%{
               amount: 1000,
               phone: "254712345678",
               callback_url: "https://example.test/mpesa/callback",
               account_reference: "LIDDR-SUB-1",
               transaction_desc: "Liddr weekly subscription"
             })

    assert response_payload["CheckoutRequestID"] == MpesaStubPlug.checkout_request_id()
    assert response_payload["MerchantRequestID"] == MpesaStubPlug.merchant_request_id()
    assert request_payload["Password"] == "[redacted]"
    refute request_payload["PhoneNumber"] == "254712345678"
  end

  test "query_stk_status returns the raw response for correlation" do
    assert {:ok, %{response_payload: response_payload}} =
             Client.query_stk_status(MpesaStubPlug.checkout_request_id())

    assert response_payload["CheckoutRequestID"] == MpesaStubPlug.checkout_request_id()
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)
end
