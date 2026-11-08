defmodule Liddr.Auth.OtpDelivery.ResendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Liddr.Auth.OtpDelivery.Resend
  alias Liddr.TestSupport.ResendStubPlug

  @env_keys ~w(RESEND_API_KEY OTP_EMAIL_FROM RESEND_API_URL RESEND_TIMEOUT_MS)
  @api_key "stub-resend-key"
  @from "Liddr <security@example.test>"

  setup do
    previous_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous_env, &restore_env/1) end)

    System.put_env("RESEND_API_KEY", @api_key)
    System.put_env("OTP_EMAIL_FROM", @from)
    :ok
  end

  test "sends the code through the Resend emails API" do
    start_resend!(200, %{"id" => "email-123"})

    assert :ok = Resend.send_otp("ops@example.test", "Your code", "Code: 123456")

    assert_receive {:resend_request, "/emails", ["Bearer " <> @api_key], payload}

    assert payload == %{
             "from" => @from,
             "to" => ["ops@example.test"],
             "subject" => "Your code",
             "text" => "Code: 123456"
           }
  end

  test "reports a provider rejection without logging the email body" do
    start_resend!(422, %{"name" => "validation_error", "message" => "Invalid from"})

    log =
      capture_log(fn ->
        assert {:error, {:http_error, 422, "validation_error"}} =
                 Resend.send_otp("ops@example.test", "Your code", "Code: 123456")
      end)

    refute log =~ "123456"
    refute log =~ @api_key
  end

  test "treats a success response without an email id as a failure" do
    start_resend!(200, %{})

    capture_log(fn ->
      assert {:error, {:http_error, 200, "unknown"}} =
               Resend.send_otp("ops@example.test", "Your code", "Code: 123456")
    end)
  end

  test "fails when the API key is not configured" do
    System.delete_env("RESEND_API_KEY")

    capture_log(fn ->
      assert {:error, {:missing_env, "RESEND_API_KEY"}} =
               Resend.send_otp("ops@example.test", "Your code", "Code: 123456")
    end)
  end

  defp start_resend!(status, body) do
    plug_opts = [test_pid: self(), status: status, body: body]

    server =
      start_supervised!(
        {Bandit,
         plug: {ResendStubPlug, plug_opts},
         scheme: :http,
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    System.put_env("RESEND_API_URL", "http://127.0.0.1:#{port}/emails")
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)
end
