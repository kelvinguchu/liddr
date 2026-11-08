defmodule LiddrWeb.ModerationIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Moderation.ReportReview
  alias Liddr.Moderation.UserEnforcement
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

  test "POST /api/moderation/enforcements replays for identical idempotency key", %{conn: _conn} do
    %{auth_conn: ops_conn} =
      AuthFixtures.authenticate_ops!("ops-mod-idem-enforcement@example.com")

    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    target = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    key = "mod-enforcement-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "warning",
        "reason_code" => "safety_review",
        "reason_text" => "Idempotency replay test"
      })
      |> json_response(201)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "warning",
        "reason_code" => "safety_review",
        "reason_text" => "Idempotency replay test"
      })
      |> json_response(201)

    assert first == second

    assert Repo.aggregate(
             from(e in UserEnforcement,
               where: e.user_id == ^target.id and e.action == "warning"
             ),
             :count,
             :id
           ) == 1
  end

  test "POST /api/moderation/reports/:id/reviews replays for identical idempotency key", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn, user_id: reviewer_id} =
      AuthFixtures.authenticate_ops!("ops-mod-idem-review@example.com")

    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    category = insert_report_category!("idem_review_case")
    reporter = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    reported = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})

    report =
      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category.id,
        status: "under_review",
        severity_level: 3,
        source: "in_app",
        incident_type: "conduct",
        description: "Idempotency moderation review test"
      })

    key = "mod-review-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/reports/#{report.id}/reviews", %{
        "decision" => "warning",
        "severity_level" => 3,
        "reason_code" => "first_offense",
        "notes" => "Review replay check"
      })
      |> json_response(201)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/reports/#{report.id}/reviews", %{
        "decision" => "warning",
        "severity_level" => 3,
        "reason_code" => "first_offense",
        "notes" => "Review replay check"
      })
      |> json_response(201)

    assert first == second

    assert Repo.aggregate(
             from(r in ReportReview,
               where: r.report_id == ^report.id and r.reviewer_user_id == ^reviewer_id
             ),
             :count,
             :id
           ) == 1
  end

  defp insert_report_category!(slug) do
    Repo.insert!(%ReportCategory{
      slug: slug,
      label: String.replace(slug, "_", " ") |> String.capitalize(),
      description: "Moderation idempotency category",
      applies_to: "both",
      severity_level_default: 3,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: true,
      display_order: 20
    })
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
