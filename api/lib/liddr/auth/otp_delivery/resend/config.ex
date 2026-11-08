defmodule Liddr.Auth.OtpDelivery.Resend.Config do
  alias Liddr.Auth.OtpDelivery.ProviderEnv

  @enforce_keys [:url, :api_key, :from, :timeout_ms]
  defstruct [:url, :api_key, :from, :timeout_ms]

  @default_url "https://api.resend.com/emails"

  def fetch do
    with {:ok, api_key} <- ProviderEnv.required("RESEND_API_KEY"),
         {:ok, from} <- ProviderEnv.required("OTP_EMAIL_FROM") do
      {:ok,
       %__MODULE__{
         url: ProviderEnv.optional("RESEND_API_URL") || @default_url,
         api_key: api_key,
         from: from,
         timeout_ms: ProviderEnv.timeout_ms("RESEND_TIMEOUT_MS")
       }}
    end
  end
end
