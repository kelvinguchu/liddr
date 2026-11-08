defmodule Liddr.Auth.OtpDelivery.HostPinnacle.Config do
  alias Liddr.Auth.OtpDelivery.ProviderEnv

  @enforce_keys [:url, :user_id, :password, :api_key, :sender_id, :timeout_ms]
  defstruct [:url, :user_id, :password, :api_key, :sender_id, :timeout_ms]

  def fetch do
    with {:ok, url} <- ProviderEnv.required("HOSTPINNACLE_API_URL"),
         {:ok, user_id} <- ProviderEnv.required("HOSTPINNACLE_USER_ID"),
         {:ok, password} <- ProviderEnv.required("HOSTPINNACLE_PASSWORD"),
         {:ok, api_key} <- ProviderEnv.required("HOSTPINNACLE_API_KEY"),
         {:ok, sender_id} <- ProviderEnv.required("HOSTPINNACLE_SENDER_ID") do
      {:ok,
       %__MODULE__{
         url: url,
         user_id: user_id,
         password: password,
         api_key: api_key,
         sender_id: sender_id,
         timeout_ms: ProviderEnv.timeout_ms("HOSTPINNACLE_TIMEOUT_MS")
       }}
    end
  end
end
