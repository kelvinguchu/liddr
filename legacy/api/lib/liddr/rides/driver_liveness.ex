defmodule Liddr.Rides.DriverLiveness do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Location.DriverLocation
  alias Liddr.Repo

  @defaults [
    online_max_age_seconds: 90,
    offline_after_seconds: 240
  ]

  def online_max_age_seconds, do: policy_value(:online_max_age_seconds)
  def offline_after_seconds, do: policy_value(:offline_after_seconds)

  def snapshot(%Driver{} = driver, now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^driver.user_id,
          select: dl
      )

    signal_at = latest_signal_at(driver.last_seen_at, location)
    age_seconds = age_seconds(signal_at, now)
    %{state: state_for_age(age_seconds), signal_at: signal_at, signal_age_seconds: age_seconds}
  end

  def state_for_age(age_seconds) when is_integer(age_seconds) and age_seconds >= 0 do
    cond do
      age_seconds <= online_max_age_seconds() -> "online"
      age_seconds <= offline_after_seconds() -> "degraded"
      true -> "offline"
    end
  end

  def state_for_age(_age_seconds), do: "offline"

  def dispatch_online_cutoff(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    DateTime.add(now, -online_max_age_seconds(), :second)
  end

  def accept_allowed?(%{state: "online"}), do: true
  def accept_allowed?(_snapshot), do: false

  defp latest_signal_at(last_seen_at, nil), do: last_seen_at
  defp latest_signal_at(nil, %DriverLocation{captured_at: captured_at}), do: captured_at

  defp latest_signal_at(last_seen_at, %DriverLocation{captured_at: captured_at}) do
    case DateTime.compare(last_seen_at, captured_at) do
      :lt -> captured_at
      _ -> last_seen_at
    end
  end

  defp age_seconds(nil, _now), do: nil

  defp age_seconds(%DateTime{} = signal_at, %DateTime{} = now),
    do: DateTime.diff(now, signal_at, :second)

  defp policy do
    @defaults
    |> Keyword.merge(Application.get_env(:liddr, __MODULE__, []))
  end

  defp policy_value(key), do: Keyword.fetch!(policy(), key)
end
