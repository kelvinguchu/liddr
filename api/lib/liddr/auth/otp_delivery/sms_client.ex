defmodule Liddr.Auth.OtpDelivery.SmsClient do
  @callback send_otp(phone :: String.t(), message :: String.t()) :: :ok | {:error, term()}
end
