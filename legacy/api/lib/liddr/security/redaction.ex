defmodule Liddr.Security.Redaction do
  @moduledoc false

  @redacted "[redacted]"
  @coordinate_keys ~w(
    pickup_lat pickup_lng dropoff_lat dropoff_lng
    old_dropoff_lat old_dropoff_lng new_dropoff_lat new_dropoff_lng
    lat lng latitude longitude
  )
  @secret_keys ~w(
    storage_key gcs_uri upload_url download_url callback_url result_url timeout_url
    body message notes note transaction_id mpesa_receipt_number merchant_request_id
    Password SecurityCredential access_token authorization token
  )
  @masked_reference_keys ~w(
    transaction_id mpesa_receipt_number merchant_request_id checkout_request_id
    TransactionID MpesaReceiptNumber MerchantRequestID CheckoutRequestID TransID ConversationID
    OriginatorConversationID
  )
  @masked_phone_keys ~w(phone phone_e164 phone_number msisdn MSISDN PhoneNumber PartyA)

  def mask_phone(value) when is_binary(value) do
    trimmed = String.trim(value)
    len = String.length(trimmed)

    cond do
      trimmed == @redacted ->
        @redacted

      len <= 4 ->
        @redacted

      len <= 7 ->
        String.first(trimmed) <> String.duplicate("*", len - 2) <> String.last(trimmed)

      true ->
        String.slice(trimmed, 0, 4) <>
          String.duplicate("*", len - 7) <> String.slice(trimmed, -3, 3)
    end
  end

  def mask_phone(_value), do: nil

  def mask_reference(value, opts \\ [])

  def mask_reference(value, opts) when is_binary(value) do
    prefix = Keyword.get(opts, :prefix, 4)
    suffix = Keyword.get(opts, :suffix, 4)
    trimmed = String.trim(value)
    len = String.length(trimmed)

    cond do
      trimmed == "" ->
        nil

      trimmed == @redacted ->
        @redacted

      len <= prefix + suffix ->
        @redacted

      true ->
        String.slice(trimmed, 0, prefix) <>
          String.duplicate("*", len - prefix - suffix) <>
          String.slice(trimmed, -suffix, suffix)
    end
  end

  def mask_reference(_value, _opts), do: nil

  def mask_vehicle_plate(value), do: mask_reference(value, prefix: 3, suffix: 1)
  def mask_license(value), do: mask_reference(value, prefix: 2, suffix: 2)

  def sanitize_payload(%{} = payload) do
    payload
    |> Enum.map(fn {key, value} -> {key, sanitize_entry(to_string(key), value)} end)
    |> Map.new()
  end

  def sanitize_payload(payload), do: payload

  defp sanitize_entry(_key, %{} = value), do: sanitize_payload(value)
  defp sanitize_entry(_key, value) when is_list(value), do: Enum.map(value, &sanitize_payload/1)

  defp sanitize_entry(key, value) when key in @coordinate_keys do
    if is_nil(value), do: nil, else: @redacted
  end

  defp sanitize_entry(key, value) when key in @masked_phone_keys, do: mask_phone(value)

  defp sanitize_entry(key, value) when key in @secret_keys do
    if is_nil(value), do: nil, else: @redacted
  end

  defp sanitize_entry(key, value) when key in @masked_reference_keys,
    do: mask_reference(value)

  defp sanitize_entry(_key, value), do: value
end
