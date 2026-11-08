defmodule Liddr.Auth.OtpDelivery.EmailClient do
  @callback send_otp(email :: String.t(), subject :: String.t(), message :: String.t()) ::
              :ok | {:error, term()}
end
