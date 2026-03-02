defmodule Liddr.Subscriptions.MpesaCallback do
  @stk_callback_path "/api/payments/mpesa/stk-callback"
  @c2b_validation_path "/api/payments/c2b-validation"
  @c2b_confirmation_path "/api/payments/c2b-confirmation"
  @tx_status_callback_path "/api/payments/tx-status-callback"

  def verify_callback_token(token) do
    expected =
      System.get_env("MPESA_CALLBACK_TOKEN") || System.get_env("MPESA_REGISTER_TOKEN")

    case normalize_text(expected) do
      nil ->
        :ok

      expected_value ->
        if normalize_text(token) == expected_value,
          do: :ok,
          else: {:error, :invalid_callback_token}
    end
  end

  def callback_token_transport do
    case normalize_text(System.get_env("MPESA_CALLBACK_TOKEN_TRANSPORT")) do
      nil -> "query"
      value -> String.downcase(value)
    end
    |> case do
      "header" -> "header"
      "query_or_header" -> "query_or_header"
      "query" -> "query"
      _ -> "query"
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
      value -> {:ok, value}
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
      value -> {:ok, value}
    end
  end

  def callback_url_for_path(path) when is_binary(path) do
    with {:ok, base} <- callback_base_url() do
      url = String.trim_trailing(base, "/") <> path

      token =
        normalize_text(
          System.get_env("MPESA_CALLBACK_TOKEN") || System.get_env("MPESA_REGISTER_TOKEN")
        )

      case {token, callback_token_transport()} do
        {nil, _transport} -> {:ok, url}
        {_token, "header"} -> {:ok, url}
        {value, _transport} -> {:ok, url <> "?token=" <> URI.encode_www_form(value)}
      end
    end
  end

  defp callback_base_url do
    base =
      System.get_env("MPESA_CALLBACK_BASE_URL")
      |> normalize_text()

    if is_nil(base), do: {:error, :missing_mpesa_callback_base_url}, else: {:ok, base}
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
