defmodule Liddr.Auth.OtpDelivery do
  require Logger

  @default_app_name "Liddr"
  @default_app_domain "liddr.app"

  def deliver_challenge(provider, identifier, code, debug_code) do
    cond do
      is_binary(debug_code) ->
        :ok

      provider == "phone_otp" ->
        identifier
        |> sms_client().send_otp(otp_message(code))
        |> delivery_result(provider)

      provider == "email_otp" ->
        identifier
        |> email_client().send_otp(email_subject(), email_message(code))
        |> delivery_result(provider)

      true ->
        delivery_result({:error, :unsupported_otp_provider}, provider)
    end
  end

  def otp_message(code) do
    app_domain = System.get_env("OTP_APP_DOMAIN") || @default_app_domain

    """
    #{app_name()} Security Code

    Your verification code is: #{code}

    This code expires in 5 minutes. Do not share this code with anyone.

    @#{app_domain} ##{code}
    """
    |> String.trim()
  end

  def email_subject, do: "Your #{app_name()} security code"

  def email_message(code) do
    """
    Your #{app_name()} verification code is: #{code}

    This code expires in 5 minutes. Do not share this code with anyone.

    If you did not request this code, you can ignore this email.
    """
    |> String.trim()
  end

  defp delivery_result(:ok, _provider), do: :ok

  defp delivery_result({:error, reason}, provider) do
    Logger.error("[auth.otp_delivery] failed provider=#{provider} reason=#{inspect(reason)}")
    {:error, :otp_delivery_unavailable}
  end

  defp app_name, do: System.get_env("OTP_APP_NAME") || @default_app_name

  defp sms_client do
    Application.get_env(:liddr, :otp_sms_client, Liddr.Auth.OtpDelivery.HostPinnacle)
  end

  defp email_client do
    Application.get_env(:liddr, :otp_email_client, Liddr.Auth.OtpDelivery.Resend)
  end
end
