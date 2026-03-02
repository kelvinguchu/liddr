defmodule Liddr.Subscriptions.ReconciliationPolicy do
  @moduledoc false

  @default_limit 50
  @default_grace_seconds 90
  @default_max_age_seconds 1_800
  @default_max_attempts 8
  @default_interval_seconds 60
  @default_backoff_seconds [30, 60, 120, 180, 300]

  def defaults do
    %{
      limit: @default_limit,
      grace_seconds: @default_grace_seconds,
      max_age_seconds: @default_max_age_seconds,
      max_attempts: @default_max_attempts,
      interval_seconds: @default_interval_seconds,
      backoff_seconds: @default_backoff_seconds
    }
  end

  def resolve(overrides \\ %{}) do
    base = defaults() |> Map.merge(load_runtime_config())

    %{
      limit: parse_int_override(overrides, [:limit], base.limit, 1, 500),
      grace_seconds:
        parse_int_override(overrides, [:grace_seconds], base.grace_seconds, 0, 86_400),
      max_age_seconds:
        parse_int_override(overrides, [:max_age_seconds], base.max_age_seconds, 60, 172_800),
      max_attempts: parse_int_override(overrides, [:max_attempts], base.max_attempts, 1, 100),
      interval_seconds:
        parse_int_override(overrides, [:interval_seconds], base.interval_seconds, 10, 3_600),
      backoff_seconds: parse_backoff_override(overrides, base.backoff_seconds)
    }
  end

  defp load_runtime_config do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      limit: parse_int(Keyword.get(config, :limit), @default_limit, 1, 500),
      grace_seconds:
        parse_int(Keyword.get(config, :grace_seconds), @default_grace_seconds, 0, 86_400),
      max_age_seconds:
        parse_int(Keyword.get(config, :max_age_seconds), @default_max_age_seconds, 60, 172_800),
      max_attempts: parse_int(Keyword.get(config, :max_attempts), @default_max_attempts, 1, 100),
      interval_seconds:
        parse_int(Keyword.get(config, :interval_seconds), @default_interval_seconds, 10, 3_600),
      backoff_seconds:
        parse_backoff(Keyword.get(config, :backoff_seconds), @default_backoff_seconds)
    }
  end

  defp parse_int_override(overrides, keys, default, min, max) do
    value =
      Enum.find_value(keys, fn key -> get_value(overrides, key) end)

    parse_int(value, default, min, max)
  end

  defp parse_backoff_override(overrides, default) do
    value = get_value(overrides, :backoff_seconds)

    parse_backoff(value, default)
  end

  defp parse_backoff(value, default) when is_list(value) do
    parsed =
      value
      |> Enum.map(&parse_int(&1, nil, 1, 86_400))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    if parsed == [], do: default, else: parsed
  end

  defp parse_backoff(value, default) when is_binary(value) do
    parsed =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> parse_backoff(default)

    if parsed == [], do: default, else: parsed
  end

  defp parse_backoff(_value, default), do: default

  defp parse_int(nil, default, _min, _max), do: default

  defp parse_int(value, default, min, max) when is_integer(value) do
    if value >= min and value <= max, do: value, else: default
  end

  defp parse_int(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parse_int(parsed, default, min, max)
      _ -> default
    end
  end

  defp parse_int(_value, default, _min, _max), do: default

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil
end
