defmodule Liddr.Subscriptions.MpesaCallback do
  alias Liddr.Payments.Mpesa.Client.Normalize

  @stk_callback_path "/api/payments/mpesa/stk-callback"
  @c2b_validation_path "/api/payments/c2b-validation"
  @c2b_confirmation_path "/api/payments/c2b-confirmation"
  @tx_status_callback_path "/api/payments/tx-status-callback"

  def verify_callback_token(token) do
    with {:ok, expected} <- fetch_callback_token() do
      if normalize_text(token) == expected do
        :ok
      else
        {:error, :invalid_callback_token}
      end
    end
  end

  def callback_token_transport do
    case normalize_text(System.get_env("MPESA_CALLBACK_TOKEN_TRANSPORT")) do
      nil -> "header"
      value -> String.downcase(value)
    end
    |> case do
      "header" -> "header"
      "query_or_header" -> "query_or_header"
      "query" -> "query"
      _ -> "header"
    end
  end

  def stk_callback_url do
    callback_url_for_path(@stk_callback_path)
  end

  def c2b_callback_urls do
    with {:ok, validation_url} <- callback_url_for_path(@c2b_validation_path),
         {:ok, confirmation_url} <- callback_url_for_path(@c2b_confirmation_path) do
      {:ok, %{validation_url: validation_url, confirmation_url: confirmation_url}}
    end
  end

  def tx_status_result_url(attrs) do
    custom_url =
      normalize_text(
        get_value(attrs, :result_url) ||
          System.get_env("MPESA_TX_STATUS_RESULT_URL")
      )

    case custom_url do
      nil -> callback_url_for_path(@tx_status_callback_path)
      value -> Normalize.url(value, :result_url)
    end
  end

  def tx_status_timeout_url(attrs) do
    custom_url =
      normalize_text(
        get_value(attrs, :timeout_url) ||
          System.get_env("MPESA_TX_STATUS_TIMEOUT_URL")
      )

    case custom_url do
      nil -> callback_url_for_path(@tx_status_callback_path)
      value -> Normalize.url(value, :timeout_url)
    end
  end

  def callback_url_for_path(path) when is_binary(path) do
    with {:ok, base} <- callback_base_url(),
         {:ok, token} <- fetch_callback_token() do
      url = String.trim_trailing(base, "/") <> path

      case callback_token_transport() do
        "header" ->
          {:ok, url}

        "query" ->
          {:ok, url <> "?token=" <> URI.encode_www_form(token)}

        "query_or_header" ->
          {:ok, url <> "?token=" <> URI.encode_www_form(token)}
      end
    end
  end

  defp callback_base_url do
    base =
      System.get_env("MPESA_CALLBACK_BASE_URL")
      |> normalize_text()

    case base do
      nil -> {:error, :missing_mpesa_callback_base_url}
      value -> Normalize.url(value, :callback_base_url)
    end
  end

  defp fetch_callback_token do
    token = System.get_env("MPESA_CALLBACK_TOKEN") |> normalize_text()
    if is_nil(token), do: {:error, :missing_callback_token_config}, else: {:ok, token}
  end

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> parsed
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
