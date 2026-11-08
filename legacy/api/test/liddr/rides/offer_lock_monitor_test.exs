defmodule Liddr.Rides.OfferLockMonitorTest do
  use Liddr.DataCase, async: false

  alias Liddr.Rides.OfferLockMonitor

  @acquire_event [:liddr, :rides, :offer_lock, :acquire]
  @blocked_event [:liddr, :rides, :offer_lock, :blocked]

  test "emits alert when unavailable ratio crosses threshold" do
    start_supervised!(
      {OfferLockMonitor,
       enabled: true,
       window_ms: 50,
       min_attempts: 4,
       unavailable_ratio_alert_threshold: 0.5,
       test_pid: self()}
    )

    emit_events!("dispatch_wave", [:acquired, :unavailable, :unavailable, :acquired])

    assert_receive {:offer_lock_monitor_alert, alert}, 1_000
    assert alert.source == "dispatch_wave"
    assert alert.attempts == 4
    assert alert.unavailable == 2
    assert_in_delta alert.unavailable_ratio, 0.5, 0.0001

    assert_receive {:offer_lock_monitor_window, _stats, _blocked, alerts}, 1_000
    assert length(alerts) == 1
  end

  test "does not alert when unavailable ratio stays below threshold" do
    start_supervised!(
      {OfferLockMonitor,
       enabled: true,
       window_ms: 50,
       min_attempts: 4,
       unavailable_ratio_alert_threshold: 0.5,
       test_pid: self()}
    )

    emit_events!("request_initial_offers", [:acquired, :acquired, :unavailable, :acquired])

    assert_receive {:offer_lock_monitor_window, _stats, _blocked, alerts}, 1_000
    assert alerts == []
    refute_receive {:offer_lock_monitor_alert, _alert}, 100
  end

  test "health exposes strict-mode dispatch blocking risk when blocked events occur" do
    previous_fallback =
      Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, true)

    Application.put_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    on_exit(fn ->
      restore_env(:ride_offer_lock_allow_unavailable_fallback, previous_fallback)
    end)

    start_supervised!(
      {OfferLockMonitor,
       enabled: true, window_ms: 5_000, min_attempts: 50, unavailable_ratio_alert_threshold: 0.8}
    )

    emit_blocked_events!("request_initial_offers", [1, 1])

    assert {:ok, health} = OfferLockMonitor.health()
    assert health.dispatch_blocking_risk.mode == "strict"
    assert health.dispatch_blocking_risk.current_window_unavailable == 0
    assert health.dispatch_blocking_risk.current_window_blocked == 2
    assert health.dispatch_blocking_risk.current_window_blocking_risk == true
    assert health.current_window.totals.blocked == 2
    assert health.current_window.by_source["request_initial_offers"].blocked == 2
    assert health.alert_recommendation.level == "critical"
    assert health.alert_recommendation.should_page == true
    assert health.alert_recommendation.code == "DISPATCH_BLOCKING_RISK"
  end

  test "flush emits external alert payload for critical recommendation when enabled" do
    previous_fallback =
      Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, true)

    previous_external = Application.get_env(:liddr, Liddr.Rides.OfferLockExternalAlerting, [])

    Application.put_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    Application.put_env(:liddr, Liddr.Rides.OfferLockExternalAlerting,
      enabled: true,
      min_level: "critical",
      webhook_url: nil,
      test_pid: self()
    )

    on_exit(fn ->
      restore_env(:ride_offer_lock_allow_unavailable_fallback, previous_fallback)
      restore_env(Liddr.Rides.OfferLockExternalAlerting, previous_external)
    end)

    start_supervised!(
      {OfferLockMonitor,
       enabled: true, window_ms: 50, min_attempts: 50, unavailable_ratio_alert_threshold: 0.8}
    )

    emit_blocked_events!("dispatch_wave", [1])

    assert_receive {:offer_lock_external_alert, payload}, 1_000
    assert payload["level"] == "critical"
    assert payload["code"] == "DISPATCH_BLOCKING_RISK"
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

  defp emit_events!(source, results) do
    Enum.each(results, fn result ->
      :telemetry.execute(@acquire_event, %{count: 1}, %{source: source, result: result})
    end)
  end

  defp emit_blocked_events!(source, counts) do
    Enum.each(counts, fn count ->
      :telemetry.execute(@blocked_event, %{count: count}, %{source: source})
    end)
  end
end
