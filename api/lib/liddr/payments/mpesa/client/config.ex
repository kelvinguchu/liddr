defmodule Liddr.Payments.Mpesa.Client.Config do
  alias Liddr.Payments.Mpesa.Client.Normalize

  @default_timeout_ms 15_000
  @default_c2b_register_path "/mpesa/c2b/v2/registerurl"

  def fetch do
    with {:ok, consumer_key} <- fetch_env("MPESA_CONSUMER_KEY"),
         {:ok, consumer_secret} <- fetch_env("MPESA_CONSUMER_SECRET"),
         {:ok, shortcode} <- fetch_env("MPESA_SHORTCODE"),
         {:ok, passkey} <- fetch_env("MPESA_PASSKEY") do
      mpesa_env =
        case System.get_env("MPESA_ENV") do
          "production" -> "production"
          _ -> "sandbox"
        end

      default_base_url =
        if mpesa_env == "production",
          do: "https://api.safaricom.co.ke",
          else: "https://sandbox.safaricom.co.ke"

      base_url =
        System.get_env("MPESA_BASE_URL")
        |> Normalize.optional_config_text(default_base_url)

      {:ok,
       %{
         consumer_key: consumer_key,
         consumer_secret: consumer_secret,
         shortcode: shortcode,
         passkey: passkey,
         base_url: String.trim_trailing(base_url, "/"),
         timeout_ms:
           System.get_env("MPESA_TIMEOUT_MS")
           |> Normalize.parse_positive_integer(@default_timeout_ms),
         transaction_type:
           System.get_env("MPESA_STK_TRANSACTION_TYPE")
           |> Normalize.optional_config_text("CustomerPayBillOnline"),
         c2b_command_id:
           System.get_env("MPESA_C2B_COMMAND_ID")
           |> Normalize.optional_config_text("CustomerPayBillOnline"),
         c2b_register_path:
           System.get_env("MPESA_C2B_REGISTER_PATH")
           |> Normalize.optional_config_text(@default_c2b_register_path),
         identifier_type:
           System.get_env("MPESA_IDENTIFIER_TYPE")
           |> Normalize.parse_positive_integer(4),
         initiator_name:
           System.get_env("MPESA_INITIATOR_NAME")
           |> Normalize.optional_config_text(nil),
         security_credential:
           System.get_env("MPESA_SECURITY_CREDENTIAL")
           |> Normalize.optional_config_text(nil),
         tx_status_command_id:
           System.get_env("MPESA_TRANSACTION_STATUS_COMMAND_ID")
           |> Normalize.optional_config_text("TransactionStatusQuery")
       }}
    end
  end

  def required_value(nil, env_key), do: {:error, {:missing_mpesa_env, env_key}}
  def required_value(value, _env_key), do: {:ok, value}

  defp fetch_env(key) do
    case System.get_env(key) do
      nil ->
        {:error, {:missing_mpesa_env, key}}

      value ->
        normalized = String.trim(value)
        if normalized == "", do: {:error, {:missing_mpesa_env, key}}, else: {:ok, normalized}
    end
  end
end
