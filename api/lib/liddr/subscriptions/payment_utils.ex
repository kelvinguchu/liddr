defmodule Liddr.Subscriptions.PaymentUtils do
  def get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  def get_value(_attrs, _key), do: nil

  def normalize_text(nil), do: nil

  def normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> parsed
    end
  end

  def normalize_text(value), do: value |> to_string() |> normalize_text()

  def parse_integer(nil, default), do: default

  def parse_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  def parse_integer(value, _default) when is_integer(value), do: value
  def parse_integer(_value, default), do: default

  def reason_message(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def reason_message(reason), do: inspect(reason)
end
