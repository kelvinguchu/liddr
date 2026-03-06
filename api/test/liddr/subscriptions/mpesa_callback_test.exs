defmodule Liddr.Subscriptions.MpesaCallbackTest do
  use ExUnit.Case, async: false

  alias Liddr.Subscriptions.MpesaCallback

  @callback_path "/api/payments/mpesa/stk-callback"

  setup do
    keys = [
      "MPESA_CALLBACK_BASE_URL",
      "MPESA_CALLBACK_TOKEN",
      "MPESA_CALLBACK_TOKEN_TRANSPORT",
      "MPESA_TX_STATUS_RESULT_URL",
      "MPESA_TX_STATUS_TIMEOUT_URL"
    ]

    previous = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "callback_token_transport defaults to header when env is not set" do
    System.delete_env("MPESA_CALLBACK_TOKEN_TRANSPORT")

    assert MpesaCallback.callback_token_transport() == "header"
  end

  test "callback_token_transport falls back to header for unsupported values" do
    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "unsupported")

    assert MpesaCallback.callback_token_transport() == "header"
  end

  test "callback_url_for_path only appends token query param in query-based modes" do
    System.put_env("MPESA_CALLBACK_BASE_URL", "https://liddr.example.com")
    System.put_env("MPESA_CALLBACK_TOKEN", "callback-token")

    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "header")
    assert {:ok, header_url} = MpesaCallback.callback_url_for_path(@callback_path)
    refute String.contains?(header_url, "?token=")

    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "query")
    assert {:ok, query_url} = MpesaCallback.callback_url_for_path(@callback_path)
    assert String.contains?(query_url, "?token=callback-token")

    System.put_env("MPESA_CALLBACK_TOKEN_TRANSPORT", "query_or_header")
    assert {:ok, dual_url} = MpesaCallback.callback_url_for_path(@callback_path)
    assert String.contains?(dual_url, "?token=callback-token")
  end

  test "tx status urls validate custom env values" do
    System.put_env("MPESA_TX_STATUS_RESULT_URL", "not a url")
    System.put_env("MPESA_TX_STATUS_TIMEOUT_URL", "https://liddr.example.com/timeout")

    assert {:error, {:invalid_mpesa_field, :result_url}} = MpesaCallback.tx_status_result_url(%{})
    assert {:ok, "https://liddr.example.com/timeout"} = MpesaCallback.tx_status_timeout_url(%{})
  end
end
