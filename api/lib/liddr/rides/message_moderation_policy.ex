defmodule Liddr.Rides.MessageModerationPolicy do
  @moduledoc false

  @defaults [
    report_window_days: 7,
    auto_restrict_threshold: 3,
    signal_cooldown_days: 2
  ]

  def report_window_days, do: fetch(:report_window_days)
  def auto_restrict_threshold, do: fetch(:auto_restrict_threshold)
  def signal_cooldown_days, do: fetch(:signal_cooldown_days)

  defp fetch(key) do
    key
    |> config()
    |> normalize_positive_integer(Keyword.fetch!(@defaults, key))
  end

  defp config(key), do: Application.get_env(:liddr, __MODULE__, []) |> Keyword.get(key)

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default
end
