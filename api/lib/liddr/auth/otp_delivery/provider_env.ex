defmodule Liddr.Auth.OtpDelivery.ProviderEnv do
  @moduledoc false

  @default_timeout_ms 15_000
  @max_timeout_ms 120_000

  def required(name) do
    case optional(name) do
      nil -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  def optional(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        normalized = String.trim(value)
        if normalized == "", do: nil, else: normalized

      _ ->
        nil
    end
  end

  def timeout_ms(name) do
    case Integer.parse(optional(name) || "") do
      {timeout_ms, ""} when timeout_ms > 0 and timeout_ms <= @max_timeout_ms -> timeout_ms
      _ -> @default_timeout_ms
    end
  end
end
