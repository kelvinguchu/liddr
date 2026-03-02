defmodule Liddr.Payments.Mpesa.Parser do
  alias Decimal, as: D

  def parse_stk_callback(payload) when is_map(payload) do
    callback = get_in(payload, ["Body", "stkCallback"])

    if is_map(callback) do
      metadata =
        callback
        |> get_in(["CallbackMetadata", "Item"])
        |> case do
          list when is_list(list) -> list
          _ -> []
        end

      parsed = %{
        merchant_request_id: to_trimmed_string(Map.get(callback, "MerchantRequestID")),
        checkout_request_id: to_trimmed_string(Map.get(callback, "CheckoutRequestID")),
        result_code: to_integer(Map.get(callback, "ResultCode"), -1),
        result_desc: to_trimmed_string(Map.get(callback, "ResultDesc")),
        amount_kes: to_decimal(find_metadata(metadata, "Amount")),
        mpesa_receipt_number: to_trimmed_string(find_metadata(metadata, "MpesaReceiptNumber")),
        transaction_date_raw: to_trimmed_string(find_metadata(metadata, "TransactionDate")),
        phone_e164: normalize_phone(find_metadata(metadata, "PhoneNumber"))
      }

      {:ok, parsed}
    else
      {:error, :invalid_stk_callback_payload}
    end
  end

  def parse_stk_callback(_payload), do: {:error, :invalid_stk_callback_payload}

  def payment_status_from_result_code(0), do: "success"
  def payment_status_from_result_code(1032), do: "cancelled"
  def payment_status_from_result_code(1037), do: "timeout"
  def payment_status_from_result_code(_), do: "failed"

  def parse_c2b_callback(payload) when is_map(payload) do
    parsed = %{
      transaction_id: to_trimmed_string(Map.get(payload, "TransID")),
      amount_kes: to_decimal(Map.get(payload, "TransAmount")),
      bill_ref_number: to_trimmed_string(Map.get(payload, "BillRefNumber")),
      phone_e164: normalize_phone(Map.get(payload, "MSISDN")),
      first_name: to_trimmed_string(Map.get(payload, "FirstName")),
      middle_name: to_trimmed_string(Map.get(payload, "MiddleName")),
      last_name: to_trimmed_string(Map.get(payload, "LastName")),
      transaction_time_raw: to_trimmed_string(Map.get(payload, "TransTime"))
    }

    if is_nil(parsed.transaction_id) do
      {:error, :invalid_c2b_callback_payload}
    else
      {:ok, parsed}
    end
  end

  def parse_c2b_callback(_payload), do: {:error, :invalid_c2b_callback_payload}

  def parse_transaction_status_callback(payload) when is_map(payload) do
    result = Map.get(payload, "Result")

    if is_map(result) do
      {:ok,
       %{
         result_type: to_integer(Map.get(result, "ResultType"), 0),
         result_code: to_integer(Map.get(result, "ResultCode"), -1),
         result_desc: to_trimmed_string(Map.get(result, "ResultDesc")),
         originator_conversation_id:
           to_trimmed_string(Map.get(result, "OriginatorConversationID")),
         conversation_id: to_trimmed_string(Map.get(result, "ConversationID")),
         transaction_id: to_trimmed_string(Map.get(result, "TransactionID"))
       }}
    else
      {:error, :invalid_transaction_status_callback_payload}
    end
  end

  def parse_transaction_status_callback(_payload),
    do: {:error, :invalid_transaction_status_callback_payload}

  defp find_metadata(items, name) do
    items
    |> Enum.find_value(fn item ->
      if Map.get(item, "Name") == name, do: Map.get(item, "Value"), else: nil
    end)
  end

  defp normalize_phone(nil), do: nil
  defp normalize_phone(value) when is_binary(value), do: sanitize_phone(value)
  defp normalize_phone(value), do: value |> to_string() |> sanitize_phone()

  defp sanitize_phone(raw_phone) do
    digits = String.replace(raw_phone, ~r/\D/, "")

    cond do
      String.starts_with?(digits, "254") and String.length(digits) == 12 ->
        digits

      String.starts_with?(digits, "0") and String.length(digits) == 10 ->
        "254" <> String.slice(digits, 1, 9)

      String.starts_with?(digits, "7") and String.length(digits) == 9 ->
        "254" <> digits

      true ->
        nil
    end
  end

  defp to_integer(nil, default), do: default
  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp to_integer(_value, default), do: default

  defp to_decimal(nil), do: nil
  defp to_decimal(%D{} = value), do: value

  defp to_decimal(value) when is_integer(value) do
    D.new(value)
  end

  defp to_decimal(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 2)
    |> D.new()
  end

  defp to_decimal(value) when is_binary(value) do
    trimmed = String.trim(value)

    case D.parse(trimmed) do
      {decimal, ""} -> decimal
      :error -> nil
    end
  end

  defp to_decimal(_value), do: nil

  defp to_trimmed_string(nil), do: nil

  defp to_trimmed_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp to_trimmed_string(value), do: value |> to_string() |> to_trimmed_string()
end
