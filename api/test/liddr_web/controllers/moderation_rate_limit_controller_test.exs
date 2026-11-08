defmodule LiddrWeb.ModerationRateLimitControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  setup do
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")

    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")

    on_exit(fn ->
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
    end)

    :ok
  end

  test "PATCH /api/moderation/reports/:id/triage enforces reviewer rate limit", %{conn: _conn} do
    limiter_key = Liddr.Moderation.ActionRateLimiter
    previous_limiter = Application.get_env(:liddr, limiter_key, [])

    Application.put_env(
      :liddr,
      limiter_key,
      Keyword.merge(previous_limiter,
        report_triage_window_seconds: 3_600,
        report_triage_max_requests: 2
      )
    )

    on_exit(fn -> Application.put_env(:liddr, limiter_key, previous_limiter) end)

    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-triage-rate-limit@example.com")
    ops_conn = AuthFixtures.with_step_up!(ops_conn)
    category = insert_report_category!("triage_rate_limit_case")
    report_ids = create_reports_for_triage!(category.id, 3)

    for report_id <- Enum.take(report_ids, 2) do
      assert %{"data" => %{"status" => "triaged"}} =
               patch(ops_conn, "/api/moderation/reports/#{report_id}/triage", %{
                 "status" => "triaged"
               })
               |> json_response(200)
    end

    blocked_report_id = List.last(report_ids)

    assert %{"error" => %{"code" => "REPORT_TRIAGE_RATE_LIMITED"}} =
             patch(ops_conn, "/api/moderation/reports/#{blocked_report_id}/triage", %{
               "status" => "triaged"
             })
             |> json_response(429)
  end

  test "POST /api/moderation/reports/:id/reviews enforces reviewer rate limit", %{conn: _conn} do
    limiter_key = Liddr.Moderation.ActionRateLimiter
    previous_limiter = Application.get_env(:liddr, limiter_key, [])

    Application.put_env(
      :liddr,
      limiter_key,
      Keyword.merge(previous_limiter,
        report_review_window_seconds: 3_600,
        report_review_max_requests: 2
      )
    )

    on_exit(fn -> Application.put_env(:liddr, limiter_key, previous_limiter) end)

    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-review-rate-limit@example.com")
    ops_conn = AuthFixtures.with_step_up!(ops_conn)
    category = insert_report_category!("review_rate_limit_case")
    report_ids = create_reports_for_review!(category.id, 3)

    for report_id <- Enum.take(report_ids, 2) do
      assert %{"data" => %{"report" => %{"status" => "dismissed"}}} =
               post(ops_conn, "/api/moderation/reports/#{report_id}/reviews", %{
                 "decision" => "dismiss",
                 "reason_code" => "insufficient_evidence",
                 "notes" => "No enforcement required."
               })
               |> json_response(201)
    end

    blocked_report_id = List.last(report_ids)

    assert %{"error" => %{"code" => "REPORT_REVIEW_RATE_LIMITED"}} =
             post(ops_conn, "/api/moderation/reports/#{blocked_report_id}/reviews", %{
               "decision" => "dismiss",
               "reason_code" => "insufficient_evidence",
               "notes" => "Expected limiter block."
             })
             |> json_response(429)
  end

  defp create_reports_for_triage!(category_id, count) do
    for seq <- 1..count do
      {reporter, reported} = insert_report_users!()

      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category_id,
        status: "submitted",
        severity_level: 3,
        source: "in_app",
        incident_type: "conduct",
        description: "Triage limiter probe #{seq}"
      }).id
    end
  end

  defp create_reports_for_review!(category_id, count) do
    for seq <- 1..count do
      {reporter, reported} = insert_report_users!()

      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category_id,
        status: "under_review",
        severity_level: 3,
        source: "in_app",
        incident_type: "conduct",
        description: "Review limiter probe #{seq}"
      }).id
    end
  end

  defp insert_report_category!(slug) do
    Repo.insert!(%ReportCategory{
      slug: "#{slug}_#{System.unique_integer([:positive])}",
      label: "Moderation Rate Limit Category",
      description: "Moderation rate limiter tests",
      applies_to: "both",
      severity_level_default: 3,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: true,
      display_order: 402
    })
  end

  defp insert_report_users! do
    reporter = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    reported = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    {reporter, reported}
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
