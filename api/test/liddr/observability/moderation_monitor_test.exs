defmodule Liddr.Observability.ModerationMonitorTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Observability.ModerationEvents
  alias Liddr.Observability.ModerationMonitor
  alias Liddr.Repo

  test "alerts when triage 429 spikes in window" do
    start_supervised!(
      {ModerationMonitor,
       enabled: true,
       window_ms: 40,
       report_triage_rate_limited_alert_count: 1,
       report_review_rate_limited_alert_count: 100,
       pending_reports_alert_threshold: 1_000,
       min_throughput_per_window: 0,
       test_pid: self()}
    )

    ModerationEvents.report_triage_rate_limited(%{reviewer_user_id: 1})

    assert_receive {:moderation_monitor_alert, %{code: "REPORT_TRIAGE_RATE_LIMITED_SPIKE"}}, 500
  end

  test "alerts when pending report backlog exists with low throughput" do
    insert_pending_report!()

    start_supervised!(
      {ModerationMonitor,
       enabled: true,
       window_ms: 40,
       report_triage_rate_limited_alert_count: 100,
       report_review_rate_limited_alert_count: 100,
       pending_reports_alert_threshold: 1,
       min_throughput_per_window: 2,
       test_pid: self()}
    )

    assert_receive {:moderation_monitor_alert, %{code: "MODERATION_DISPUTE_THROUGHPUT_LOW"}}, 500
  end

  defp insert_pending_report! do
    reporter = Repo.insert!(%User{phone: unique_phone()})
    reported = Repo.insert!(%User{phone: unique_phone()})

    category =
      Repo.insert!(%ReportCategory{
        slug: "monitor_test_#{System.unique_integer([:positive])}",
        label: "Monitor Test",
        description: "Monitor throughput test category",
        applies_to: "both",
        severity_level_default: 3,
        recommended_action: "review",
        requires_immediate_attention: false,
        is_active: true,
        display_order: 999
      })

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "submitted",
      severity_level: 3,
      source: "in_app",
      incident_type: "conduct",
      description: "Pending report for throughput alert test"
    })
  end

  defp unique_phone do
    "2547#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(8, "0") |> String.slice(-8, 8)}"
  end
end
