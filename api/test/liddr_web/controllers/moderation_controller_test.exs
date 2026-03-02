defmodule LiddrWeb.ModerationControllerTest do
  use LiddrWeb.ConnCase, async: true

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  test "POST /api/moderation/enforcements requires bearer token", %{conn: conn} do
    target = Repo.insert!(%User{phone: "254701000001"})

    conn =
      post(conn, "/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "warning"
      })

    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "POST /api/moderation/enforcements forbids non ops/admin", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn, "0713000001")
    target = Repo.insert!(%User{phone: "254701000101"})

    conn =
      post(auth_conn, "/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "warning"
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/moderation/enforcements allows ops and updates target account status", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn, user_id: actor_id} =
      AuthFixtures.authenticate_ops!("ops2@example.com")

    target = Repo.insert!(%User{phone: "254701000201"})
    ends_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    conn =
      post(auth_conn, "/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "temporary_suspension",
        "ends_at" => DateTime.to_iso8601(ends_at),
        "reason_code" => "safety_review"
      })

    assert %{
             "data" => %{
               "user_id" => user_id,
               "actor_user_id" => reporter_id,
               "action" => "temporary_suspension",
               "status" => "active"
             }
           } = json_response(conn, 201)

    assert user_id == target.id
    assert reporter_id == actor_id

    updated_user = Repo.get!(User, target.id)
    assert updated_user.account_status == "suspended"
    assert updated_user.account_status_reason_code == "safety_review"
  end

  test "POST /api/moderation/enforcements forces driver offline when suspended", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-driver-suspend@example.com")
    category_id = VerificationFixtures.insert_vehicle_category!()
    target = Repo.insert!(%User{phone: "254701000301"})

    _driver =
      VerificationFixtures.create_driver!(
        user: target,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    ends_at = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    conn =
      post(auth_conn, "/api/moderation/enforcements", %{
        "user_id" => target.id,
        "action" => "temporary_suspension",
        "ends_at" => DateTime.to_iso8601(ends_at),
        "reason_code" => "safety_review"
      })

    assert %{"data" => %{"action" => "temporary_suspension"}} = json_response(conn, 201)

    updated_driver = Repo.get!(Driver, target.id)
    assert updated_driver.account_status == "suspended"
    assert updated_driver.is_available == false
    assert Repo.aggregate(DriverActivityEvent, :count, :id) == 1
  end

  test "GET /api/moderation/reports lists and filters by status for ops", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-list@example.com")
    category = insert_report_category!("payment_dispute")
    {reporter, reported} = insert_report_users!()

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "submitted",
      severity_level: 3,
      source: "in_app",
      incident_type: "payment",
      description: "Pending report"
    })

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "resolved",
      severity_level: 2,
      source: "in_app",
      incident_type: "conduct",
      description: "Resolved report"
    })

    conn = get(auth_conn, "/api/moderation/reports?status=submitted")

    assert %{"data" => %{"reports" => reports}} = json_response(conn, 200)
    assert length(reports) == 1
    assert hd(reports)["status"] == "submitted"
  end

  test "GET /api/moderation/reports supports pagination and sorting", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-report-sort@example.com")
    category = insert_report_category!("report_sort_case")
    {reporter, reported} = insert_report_users!()

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "submitted",
      severity_level: 5,
      source: "in_app",
      incident_type: "payment",
      description: "High severity"
    })

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "submitted",
      severity_level: 1,
      source: "in_app",
      incident_type: "payment",
      description: "Low severity"
    })

    Repo.insert!(%Report{
      reporter_user_id: reporter.id,
      reported_user_id: reported.id,
      category_id: category.id,
      status: "submitted",
      severity_level: 3,
      source: "in_app",
      incident_type: "payment",
      description: "Medium severity"
    })

    page_1_conn =
      get(
        auth_conn,
        "/api/moderation/reports?sort_by=severity_level&sort_order=asc&per_page=2&page=1"
      )

    assert %{"data" => %{"reports" => reports_page_1}} = json_response(page_1_conn, 200)
    assert Enum.map(reports_page_1, & &1["severity_level"]) == [1, 3]

    page_2_conn =
      get(
        auth_conn,
        "/api/moderation/reports?sort_by=severity_level&sort_order=asc&per_page=2&page=2"
      )

    assert %{"data" => %{"reports" => reports_page_2}} = json_response(page_2_conn, 200)
    assert Enum.map(reports_page_2, & &1["severity_level"]) == [5]
  end

  test "PATCH /api/moderation/reports/:id/triage updates report status and reviewer", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn, user_id: reviewer_id} =
      AuthFixtures.authenticate_ops!("ops-triage@example.com")

    category = insert_report_category!("unsafe_driving")
    {reporter, reported} = insert_report_users!()

    report =
      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category.id,
        status: "submitted",
        severity_level: 4,
        source: "in_app",
        incident_type: "safety",
        description: "Needs triage"
      })

    conn =
      patch(auth_conn, "/api/moderation/reports/#{report.id}/triage", %{
        "status" => "triaged"
      })

    assert %{
             "data" => %{
               "id" => report_id,
               "status" => "triaged",
               "assigned_reviewer_user_id" => assigned_reviewer_id
             }
           } = json_response(conn, 200)

    assert report_id == report.id
    assert assigned_reviewer_id == reviewer_id
  end

  test "POST /api/moderation/reports/:id/reviews creates review and resolves report", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn, user_id: reviewer_id} =
      AuthFixtures.authenticate_ops!("ops-review@example.com")

    category = insert_report_category!("harassment_or_abuse")
    {reporter, reported} = insert_report_users!()

    report =
      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category.id,
        status: "under_review",
        severity_level: 5,
        source: "in_app",
        incident_type: "conduct",
        description: "Reviewed case"
      })

    conn =
      post(auth_conn, "/api/moderation/reports/#{report.id}/reviews", %{
        "decision" => "warning",
        "severity_level" => 4,
        "reason_code" => "first_offense",
        "notes" => "Warning issued after review."
      })

    assert %{
             "data" => %{
               "report" => %{
                 "status" => "resolved",
                 "resolution_outcome" => "warning"
               },
               "review" => %{
                 "report_id" => report_id,
                 "reviewer_user_id" => report_reviewer_id,
                 "decision" => "warning"
               }
             }
           } = json_response(conn, 201)

    assert report_id == report.id
    assert report_reviewer_id == reviewer_id
  end

  test "POST /api/moderation/reports/:id/reviews auto-applies permanent ban enforcement", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn, user_id: reviewer_id} =
      AuthFixtures.authenticate_ops!("ops-review-ban@example.com")

    category_id = VerificationFixtures.insert_vehicle_category!()
    reporter = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    reported = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    category = insert_report_category!("safety_critical_case")

    _driver =
      VerificationFixtures.create_driver!(
        user: reported,
        vehicle_category_id: category_id,
        account_status: "active",
        verification_status: "approved",
        subscription_status: "active",
        is_available: true
      )

    report =
      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category.id,
        status: "under_review",
        severity_level: 5,
        source: "in_app",
        incident_type: "safety",
        description: "Critical safety violation"
      })

    conn =
      post(auth_conn, "/api/moderation/reports/#{report.id}/reviews", %{
        "decision" => "permanent_ban",
        "reason_code" => "critical_safety",
        "notes" => "Permanent ban approved."
      })

    assert %{
             "data" => %{
               "report" => %{"status" => "resolved", "resolution_outcome" => "permanent_ban"},
               "review" => %{"reviewer_user_id" => ^reviewer_id}
             }
           } = json_response(conn, 201)

    enforcement =
      Repo.one!(
        from e in UserEnforcement,
          where: e.report_id == ^report.id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

    assert enforcement.action == "permanent_ban"
    assert enforcement.status == "active"
    assert enforcement.actor_user_id == reviewer_id

    updated_user = Repo.get!(User, reported.id)
    updated_driver = Repo.get!(Driver, reported.id)
    assert updated_user.account_status == "banned"
    assert updated_driver.account_status == "deactivated"
    assert updated_driver.is_available == false
  end

  test "POST /api/moderation/reports/:id/reviews requires ends_at for temporary suspension", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-review-temp@example.com")
    category = insert_report_category!("temp_suspend_case")
    {reporter, reported} = insert_report_users!()

    report =
      Repo.insert!(%Report{
        reporter_user_id: reporter.id,
        reported_user_id: reported.id,
        category_id: category.id,
        status: "under_review",
        severity_level: 4,
        source: "in_app",
        incident_type: "conduct",
        description: "Needs temporary suspension"
      })

    conn =
      post(auth_conn, "/api/moderation/reports/#{report.id}/reviews", %{
        "decision" => "temporary_suspension",
        "reason_code" => "conduct_violation",
        "notes" => "No end timestamp provided"
      })

    assert %{"error" => %{"code" => "MISSING_ENFORCEMENT_ENDS_AT"}} = json_response(conn, 422)
  end

  test "GET /api/moderation/enforcements lists and filters by action", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-enforcement-list@example.com")
    target = Repo.insert!(%User{phone: "254701100001"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("user_enforcements", [
      %{
        user_id: target.id,
        scope: "platform",
        action: "warning",
        status: "active",
        starts_at: now,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      },
      %{
        user_id: target.id,
        scope: "platform",
        action: "feature_restriction",
        status: "active",
        starts_at: now,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      }
    ])

    conn = get(auth_conn, "/api/moderation/enforcements?action=warning")

    assert %{"data" => %{"enforcements" => enforcements}} = json_response(conn, 200)
    assert length(enforcements) == 1
    assert hd(enforcements)["action"] == "warning"
  end

  test "GET /api/moderation/enforcements supports pagination and sorting", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-enforcement-sort@example.com")
    target = Repo.insert!(%User{phone: "254701100011"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("user_enforcements", [
      %{
        user_id: target.id,
        scope: "platform",
        action: "warning",
        status: "active",
        starts_at: now,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      },
      %{
        user_id: target.id,
        scope: "platform",
        action: "feature_restriction",
        status: "active",
        starts_at: now,
        inserted_at: now,
        updated_at: now,
        metadata: %{}
      }
    ])

    page_1_conn =
      get(
        auth_conn,
        "/api/moderation/enforcements?sort_by=action&sort_order=asc&per_page=1&page=1"
      )

    assert %{"data" => %{"enforcements" => page_1}} = json_response(page_1_conn, 200)
    assert length(page_1) == 1
    assert hd(page_1)["action"] == "feature_restriction"

    page_2_conn =
      get(
        auth_conn,
        "/api/moderation/enforcements?sort_by=action&sort_order=asc&per_page=1&page=2"
      )

    assert %{"data" => %{"enforcements" => page_2}} = json_response(page_2_conn, 200)
    assert length(page_2) == 1
    assert hd(page_2)["action"] == "warning"
  end

  defp insert_report_category!(slug) do
    Repo.insert!(%ReportCategory{
      slug: slug,
      label: String.replace(slug, "_", " ") |> String.capitalize(),
      description: "Moderation test category",
      applies_to: "both",
      severity_level_default: 3,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: true,
      display_order: 10
    })
  end

  defp insert_report_users! do
    reporter = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    reported = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    {reporter, reported}
  end
end
