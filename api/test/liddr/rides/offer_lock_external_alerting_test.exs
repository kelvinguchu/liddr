defmodule Liddr.Rides.OfferLockExternalAlertingTest do
  use Liddr.DataCase, async: true

  alias Liddr.Rides.OfferLockExternalAlerting

  test "notifies external sink for critical recommendation when enabled" do
    payload = %{
      alert_recommendation: %{level: "critical", code: "DISPATCH_BLOCKING_RISK", message: "risk"},
      dispatch_blocking_risk: %{mode: "strict"},
      current_window: %{},
      last_window: %{}
    }

    assert :ok =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               provider: "raw",
               min_level: "critical",
               webhook_url: nil,
               test_pid: self()
             )

    assert_receive {:offer_lock_external_alert, external_payload}, 1_000
    assert external_payload["level"] == "critical"
    assert external_payload["code"] == "DISPATCH_BLOCKING_RISK"
  end

  test "formats Slack payload when provider is slack" do
    payload = %{
      alert_recommendation: %{
        level: "warning",
        code: "LOCK_UNAVAILABLE_RATIO_HIGH",
        message: "warn"
      },
      dispatch_blocking_risk: %{mode: "fallback", current_window_blocked: 0},
      current_window: %{},
      last_window: %{}
    }

    assert :ok =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               provider: "slack",
               min_level: "warning",
               webhook_url: nil,
               slack_channel: "#ops-alerts",
               slack_username: "Liddr Monitor",
               test_pid: self()
             )

    assert_receive {:offer_lock_external_alert, external_payload}, 1_000
    assert external_payload["text"] =~ "[Liddr][WARNING]"
    assert external_payload["channel"] == "#ops-alerts"
    assert external_payload["username"] == "Liddr Monitor"
    assert is_list(external_payload["blocks"])
  end

  test "formats PagerDuty payload when provider is pagerduty_events_v2" do
    payload = %{
      alert_recommendation: %{level: "critical", code: "DISPATCH_BLOCKING_RISK", message: "risk"},
      dispatch_blocking_risk: %{mode: "strict"},
      current_window: %{},
      last_window: %{}
    }

    assert :ok =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               provider: "pagerduty_events_v2",
               min_level: "critical",
               webhook_url: nil,
               pagerduty_routing_key: "pd-routing-key",
               test_pid: self()
             )

    assert_receive {:offer_lock_external_alert, external_payload}, 1_000
    assert external_payload["routing_key"] == "pd-routing-key"
    assert external_payload["event_action"] == "trigger"
    assert external_payload["payload"]["severity"] == "critical"
  end

  test "does not notify for ok recommendation" do
    payload = %{alert_recommendation: %{level: "ok", code: "NONE", message: "ok"}}

    assert :ok =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               min_level: "warning",
               test_pid: self()
             )

    refute_receive {:offer_lock_external_alert, _payload}, 200
  end

  test "returns missing webhook when enabled and sink not configured" do
    payload = %{alert_recommendation: %{level: "critical", code: "DISPATCH_BLOCKING_RISK"}}

    assert {:error, :missing_webhook_url} =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               min_level: "critical",
               webhook_url: nil
             )
  end

  test "returns missing pagerduty routing key when pagerduty provider is selected" do
    payload = %{alert_recommendation: %{level: "critical", code: "DISPATCH_BLOCKING_RISK"}}

    assert {:error, :missing_pagerduty_routing_key} =
             OfferLockExternalAlerting.notify(payload,
               enabled: true,
               provider: "pagerduty_events_v2",
               min_level: "critical",
               webhook_url: "https://events.pagerduty.com/v2/enqueue"
             )
  end
end
