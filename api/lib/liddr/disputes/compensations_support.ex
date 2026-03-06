defmodule Liddr.Disputes.CompensationsSupport do
  @moduledoc false

  alias Liddr.Moderation.Query

  @processing_channels ~w(manual_ops mpesa_reversal wallet_credit bank_transfer)

  def parse_positive_integer(value, _reason) when is_integer(value) and value > 0,
    do: {:ok, value}

  def parse_positive_integer(value, reason) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, reason}
    end
  end

  def parse_positive_integer(_value, reason), do: {:error, reason}

  def parse_positive_decimal(value) when is_integer(value) and value > 0,
    do: {:ok, Decimal.new(value)}

  def parse_positive_decimal(value) when is_float(value) and value > 0,
    do: {:ok, Decimal.from_float(value) |> Decimal.round(2)}

  def parse_positive_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.compare(decimal, Decimal.new(0)) == :gt do
          {:ok, Decimal.round(decimal, 2)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def parse_positive_decimal(_value), do: :error

  def resolve_processing_reference("paid", attrs) do
    reference =
      Query.get_value(attrs, :processing_reference) ||
        Query.get_value(attrs, :transaction_reference) ||
        Query.get_value(attrs, :payout_reference)

    case normalize_text(reference) do
      nil -> {:error, :missing_compensation_processing_reference}
      value when byte_size(value) > 128 -> {:error, :invalid_compensation_processing_reference}
      value -> {:ok, value}
    end
  end

  def resolve_processing_reference(_target_status, attrs),
    do:
      {:ok,
       normalize_text(
         Query.get_value(attrs, :processing_reference) ||
           Query.get_value(attrs, :transaction_reference) ||
           Query.get_value(attrs, :payout_reference)
       )}

  def resolve_processing_channel(attrs) do
    channel = normalize_text(Query.get_value(attrs, :processing_channel)) || "manual_ops"

    if channel in @processing_channels,
      do: {:ok, channel},
      else: {:error, :invalid_compensation_processing_channel}
  end

  def processing_event(
        from_status,
        to_status,
        actor_user_id,
        processed_at,
        reason_text,
        processing_reference,
        processing_channel
      ) do
    event = %{
      "from_status" => from_status,
      "to_status" => to_status,
      "processed_by_user_id" => actor_user_id,
      "processed_at" => DateTime.to_iso8601(processed_at),
      "processing_reference" => processing_reference,
      "processing_channel" => processing_channel
    }

    if is_binary(reason_text) and reason_text != "" do
      Map.put(event, "reason_text", reason_text)
    else
      event
    end
  end

  def normalize_metadata(%{} = metadata), do: metadata
  def normalize_metadata(_metadata), do: %{}

  def normalize_text(nil), do: nil

  def normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_text(value), do: value |> to_string() |> normalize_text()
end
