defmodule Liddr.Payments.Mpesa.Client.Normalize do
  def fetch_required(input, key) do
    value = Map.get(input, key) || Map.get(input, Atom.to_string(key))

    case text(value) do
      nil -> {:error, {:missing_mpesa_field, key}}
      parsed -> {:ok, parsed}
    end
  end

  def amount(nil), do: {:error, :invalid_mpesa_amount}
  def amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}
  def amount(amount) when is_float(amount) and amount > 0, do: {:ok, round(amount)}

  def amount(amount) when is_binary(amount) do
    case Float.parse(String.trim(amount)) do
      {parsed, ""} when parsed > 0 -> {:ok, round(parsed)}
      _ -> {:error, :invalid_mpesa_amount}
    end
  end

  def amount(_amount), do: {:error, :invalid_mpesa_amount}

  def phone(raw_phone) do
    digits =
      raw_phone
      |> to_string()
      |> String.replace(~r/\D/, "")

    cond do
      String.starts_with?(digits, "254") and String.length(digits) == 12 ->
        {:ok, digits}

      String.starts_with?(digits, "0") and String.length(digits) == 10 ->
        {:ok, "254" <> String.slice(digits, 1, 9)}

      String.starts_with?(digits, "7") and String.length(digits) == 9 ->
        {:ok, "254" <> digits}

      true ->
        {:error, :invalid_mpesa_phone}
    end
  end

  def checkout_request_id(raw_value) do
    case text(raw_value) do
      nil -> {:error, :invalid_checkout_request_id}
      value -> {:ok, value}
    end
  end

  def url(raw_value, field_name) do
    case text(raw_value) do
      nil ->
        {:error, {:missing_mpesa_field, field_name}}

      value ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            {:ok, value}

          _ ->
            {:error, {:invalid_mpesa_field, field_name}}
        end
    end
  end

  def optional_text(nil, default), do: default

  def optional_text(value, default) do
    case text(value) do
      nil -> default
      parsed -> parsed
    end
  end

  def parse_positive_integer(nil, default), do: default

  def parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  def parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  def parse_positive_integer(_value, default), do: default

  def optional_config_text(nil, default), do: default

  def optional_config_text(value, default) do
    case text(value) do
      nil -> default
      parsed -> parsed
    end
  end

  def text(nil), do: nil

  def text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> parsed
    end
  end

  def text(value), do: value |> to_string() |> text()
end
