defmodule Liddr.Rides.Integrity.Policy do
  @moduledoc false

  @default_policy [
    rolling_window_days: 7,
    rider_chargeable_threshold: 5,
    rider_chargeable_escalation_threshold: 8,
    rider_prepay_only_days: 7,
    rider_prepay_only_escalation_days: 14,
    driver_chargeable_threshold: 5,
    driver_chargeable_escalation_threshold: 8,
    driver_temp_suspension_days: 1,
    driver_temp_suspension_escalation_days: 3,
    rider_free_cancel_grace_seconds: 120,
    rider_driver_late_waiver_seconds: 300,
    rider_driver_location_stale_seconds: 120,
    rider_no_progress_elapsed_seconds: 180,
    rider_no_progress_delta_m: 100,
    rider_moving_away_elapsed_seconds: 120,
    rider_moving_away_delta_m: 300,
    rider_pickup_far_distance_m: 2_000,
    rider_prepay_payment_mode: "in_app_mpesa",
    pickup_auto_reassign_enabled: true,
    pickup_auto_reassign_after_seconds: 420,
    pickup_auto_cancel_enabled: true,
    pickup_auto_cancel_after_seconds: 900,
    pickup_auto_cancel_min_reassign_count: 1,
    pickup_watchdog_limit: 100
  ]

  def rolling_window_days, do: fetch(:rolling_window_days)
  def rider_chargeable_threshold, do: fetch(:rider_chargeable_threshold)
  def rider_chargeable_escalation_threshold, do: fetch(:rider_chargeable_escalation_threshold)
  def rider_prepay_only_days, do: fetch(:rider_prepay_only_days)
  def rider_prepay_only_escalation_days, do: fetch(:rider_prepay_only_escalation_days)
  def driver_chargeable_threshold, do: fetch(:driver_chargeable_threshold)
  def driver_chargeable_escalation_threshold, do: fetch(:driver_chargeable_escalation_threshold)
  def driver_temp_suspension_days, do: fetch(:driver_temp_suspension_days)
  def driver_temp_suspension_escalation_days, do: fetch(:driver_temp_suspension_escalation_days)
  def rider_free_cancel_grace_seconds, do: fetch(:rider_free_cancel_grace_seconds)
  def rider_driver_late_waiver_seconds, do: fetch(:rider_driver_late_waiver_seconds)
  def rider_driver_location_stale_seconds, do: fetch(:rider_driver_location_stale_seconds)
  def rider_no_progress_elapsed_seconds, do: fetch(:rider_no_progress_elapsed_seconds)
  def rider_no_progress_delta_m, do: fetch(:rider_no_progress_delta_m)
  def rider_moving_away_elapsed_seconds, do: fetch(:rider_moving_away_elapsed_seconds)
  def rider_moving_away_delta_m, do: fetch(:rider_moving_away_delta_m)
  def rider_pickup_far_distance_m, do: fetch(:rider_pickup_far_distance_m)
  def rider_prepay_payment_mode, do: fetch(:rider_prepay_payment_mode)
  def pickup_auto_reassign_enabled, do: fetch(:pickup_auto_reassign_enabled)
  def pickup_auto_reassign_after_seconds, do: fetch(:pickup_auto_reassign_after_seconds)
  def pickup_auto_cancel_enabled, do: fetch(:pickup_auto_cancel_enabled)
  def pickup_auto_cancel_after_seconds, do: fetch(:pickup_auto_cancel_after_seconds)
  def pickup_auto_cancel_min_reassign_count, do: fetch(:pickup_auto_cancel_min_reassign_count)
  def pickup_watchdog_limit, do: fetch(:pickup_watchdog_limit)

  def rolling_window_start(now) do
    DateTime.add(now, -rolling_window_days() * 86_400, :second)
  end

  defp fetch(key) do
    policy =
      @default_policy
      |> Keyword.merge(Application.get_env(:liddr, __MODULE__, []))

    Keyword.fetch!(policy, key)
  end
end
