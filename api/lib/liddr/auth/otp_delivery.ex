defmodule Liddr.Auth.OtpDelivery do
  require Logger

  @default_app_name "Liddr"
  @default_app_domain "liddr.app"

  def deliver_challenge(provider, identifier, code, debug_code) do
    cond do
      is_binary(debug_code) ->
        :ok

      provider == "phone_otp" ->
        sms_client().send_otp(identifier, otp_message(code))
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[auth.otp_delivery] failed provider=phone_otp reason=#{inspect(reason)}"
            )

            {:error, :otp_delivery_unavailable}
        end

      true ->
        :ok
    end
  end

  def otp_message(code) do
    app_name = System.get_env("OTP_APP_NAME") || @default_app_name
    app_domain = System.get_env("OTP_APP_DOMAIN") || @default_app_domain

    """
    #{app_name} Security Code

    Your verification code is: #{code}

    This code expires in 5 minutes. Do not share this code with anyone.

    @#{app_domain} ##{code}
    """
    |> String.trim()
  end

  defp sms_client do
    Application.get_env(:liddr, :otp_sms_client, Liddr.Auth.OtpDelivery.HostPinnacle)
  end
end
