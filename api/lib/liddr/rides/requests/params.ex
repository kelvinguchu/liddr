defmodule Liddr.Rides.Requests.Params do
  @moduledoc false

  alias Liddr.Subscriptions.PaymentUtils

  def resolve_offer_limit(attrs, default, max) do
    attrs
    |> PaymentUtils.get_value(:offer_limit)
    |> parse_positive_integer()
    |> clamp(default, max)
  end

  def resolve_offer_ttl_seconds(attrs, default, max) do
    attrs
    |> PaymentUtils.get_value(:offer_ttl_seconds)
    |> parse_positive_integer()
    |> clamp(default, max)
  end

  def parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  def parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  def parse_positive_integer(_value), do: nil

  def to_float_or_nil(%Decimal{} = value), do: Decimal.to_float(value)
  def to_float_or_nil(value) when is_float(value), do: value
  def to_float_or_nil(value) when is_integer(value), do: value * 1.0

  def to_float_or_nil(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def to_float_or_nil(_value), do: nil

  def resolve_metadata_overrides(opts) when is_list(opts) do
    opts
    |> Keyword.get(:metadata_overrides, %{})
    |> normalize_metadata_overrides()
  end

  def resolve_metadata_overrides(_opts), do: %{}

  defp clamp(nil, default, _max), do: default
  defp clamp(value, _default, max) when value > max, do: max
  defp clamp(value, _default, _max), do: value

  defp normalize_metadata_overrides(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn
      {key, value}, acc when is_binary(key) ->
        if is_map(value), do: Map.put(acc, key, value), else: acc

      {key, value}, acc when is_atom(key) ->
        if is_map(value), do: Map.put(acc, Atom.to_string(key), value), else: acc

      _, acc ->
        acc
    end)
  end

  defp normalize_metadata_overrides(_overrides), do: %{}
end
