defmodule Liddr.TestSupport.OtpSmsTestClient do
  @behaviour Liddr.Auth.OtpDelivery.SmsClient

  @impl true
  def send_otp(identifier, message) when is_binary(identifier) and is_binary(message) do
    maybe_notify_test_process(identifier, message)

    case Application.get_env(:liddr, :otp_sms_test_result, :ok) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> other
    end
  end

  def send_otp(_identifier, _message), do: {:error, :invalid_sms_payload}

  defp maybe_notify_test_process(identifier, message) do
    case Application.get_env(:liddr, :otp_sms_test_pid) do
      pid when is_pid(pid) -> send(pid, {:otp_sms_sent, identifier, message})
      _ -> :ok
    end
  end
end
