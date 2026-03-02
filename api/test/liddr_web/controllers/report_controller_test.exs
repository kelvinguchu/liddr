defmodule LiddrWeb.ReportControllerTest do
  use LiddrWeb.ConnCase, async: true

  alias Liddr.Accounts.User
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  test "GET /api/reports/categories filters active categories by applies_to", %{conn: conn} do
    insert_category!("driver_only", "driver", true, 10)
    insert_category!("both_scope", "both", true, 20)
    insert_category!("inactive_driver", "driver", false, 30)
    insert_category!("passenger_only", "passenger", true, 40)

    conn = get(conn, "/api/reports/categories?applies_to=driver")

    assert %{"data" => %{"categories" => categories}} = json_response(conn, 200)
    slugs = Enum.map(categories, & &1["slug"])

    assert slugs == ["driver_only", "both_scope"]
  end

  test "POST /api/reports requires bearer token", %{conn: conn} do
    reported = Repo.insert!(%User{phone: "254700010002"})
    insert_category!("unsafe_driving", "both", true, 10, 5)

    conn =
      post(conn, "/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => "Unsafe maneuver."
      })

    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "POST /api/reports uses authenticated user as reporter", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: reporter_id} =
      AuthFixtures.authenticate_rider!(conn, "0710000001")

    spoofed_reporter = Repo.insert!(%User{phone: "254700010010"})
    reported = Repo.insert!(%User{phone: "254700010011"})
    insert_category!("unsafe_driving", "both", true, 10, 5)

    conn =
      post(auth_conn, "/api/reports", %{
        "reporter_user_id" => spoofed_reporter.id,
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => "Driver was dangerously weaving in traffic."
      })

    assert %{
             "data" => %{
               "reporter_user_id" => ^reporter_id,
               "severity_level" => 5,
               "status" => "submitted",
               "source" => "in_app",
               "incident_type" => "conduct"
             }
           } = json_response(conn, 201)
  end

  test "POST /api/reports forbids ops/admin roles", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops1@example.com")
    reported = Repo.insert!(%User{phone: "254700019991"})
    insert_category!("unsafe_driving", "both", true, 10, 5)

    conn =
      post(auth_conn, "/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => "Unsafe maneuver."
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/reports requires reported_driver_id for driver categories", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn, "0710000002")
    reported = Repo.insert!(%User{phone: "254700020002"})

    insert_category!("vehicle_condition_issue", "driver", true, 10, 3)

    conn =
      post(auth_conn, "/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "vehicle_condition_issue",
        "description" => "Vehicle had unsafe tires."
      })

    assert %{"error" => %{"code" => "REPORTED_DRIVER_REQUIRED"}} = json_response(conn, 422)
  end

  defp insert_category!(slug, applies_to, is_active, display_order, severity \\ 3) do
    Repo.insert!(%ReportCategory{
      slug: slug,
      label: String.replace(slug, "_", " ") |> String.capitalize(),
      description: "Test category",
      applies_to: applies_to,
      severity_level_default: severity,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: is_active,
      display_order: display_order
    })
  end
end
