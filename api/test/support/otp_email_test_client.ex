defmodule Liddr.TestSupport.OtpEmailTestClient do
  @behaviour Liddr.Auth.OtpDelivery.EmailClient

  @impl true
  def send_otp(email, subject, message) do
    case Application.get_env(:liddr, :otp_email_test_pid) do
      pid when is_pid(pid) -> send(pid, {:otp_email_sent, email, subject, message})
      _ -> :ok
    end

    Application.get_env(:liddr, :otp_email_test_result, :ok)
  end
end
