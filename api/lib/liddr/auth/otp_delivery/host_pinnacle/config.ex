defmodule Liddr.Auth.OtpDelivery.HostPinnacle.Config do
  @enforce_keys [:url, :user_id, :password, :api_key, :sender_id, :timeout_ms]
  defstruct [:url, :user_id, :password, :api_key, :sender_id, :timeout_ms]

  @default_timeout_ms 15_000
  @max_timeout_ms 120_000

  def fetch do
    with {:ok, url} <- required_env("HOSTPINNACLE_API_URL"),
         {:ok, user_id} <- required_env("HOSTPINNACLE_USER_ID"),
         {:ok, password} <- required_env("HOSTPINNACLE_PASSWORD"),
         {:ok, api_key} <- required_env("HOSTPINNACLE_API_KEY"),
         {:ok, sender_id} <- required_env("HOSTPINNACLE_SENDER_ID") do
      {:ok,
       %__MODULE__{
         url: url,
         user_id: user_id,
         password: password,
         api_key: api_key,
         sender_id: sender_id,
         timeout_ms: timeout_ms()
       }}
    end
  end

  defp required_env(name) do
    case normalized_env(name) do
      nil -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  defp timeout_ms do
    case Integer.parse(normalized_env("HOSTPINNACLE_TIMEOUT_MS") || "") do
      {timeout_ms, ""} when timeout_ms > 0 and timeout_ms <= @max_timeout_ms -> timeout_ms
      _ -> @default_timeout_ms
    end
  end

  defp normalized_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        normalized = String.trim(value)
        if normalized == "", do: nil, else: normalized

      _ ->
        nil
    end
  end
end
