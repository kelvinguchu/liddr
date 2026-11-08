defmodule LiddrWeb.ModerationEnforcementMetricsControllerTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
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

  test "GET /api/moderation/enforcements/metrics requires auth", %{conn: conn} do
    conn = get(conn, "/api/moderation/enforcements/metrics")

    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "GET /api/moderation/enforcements/metrics rejects invalid due_within_hours", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-metrics-invalid@example.com")

    conn =
      get(
        auth_conn,
        "/api/moderation/enforcements/metrics?due_within_hours=0"
      )

    assert %{"error" => %{"code" => "INVALID_DUE_WITHIN_HOURS"}} = json_response(conn, 422)
  end

  test "GET /api/moderation/enforcements/metrics returns grouped counts and due signals", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-metrics-ok@example.com")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    platform_target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})
    rides_target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    _ =
      insert_enforcement!(%{
        user_id: platform_target.id,
        scope: "platform",
        action: "warning",
        status: "active",
        starts_at: DateTime.add(now, -3600, :second),
        ends_at: nil
      })

    _ =
      insert_enforcement!(%{
        user_id: platform_target.id,
        scope: "platform",
        action: "temporary_suspension",
        status: "active",
        starts_at: DateTime.add(now, -1200, :second),
        ends_at: DateTime.add(now, 1800, :second)
      })

    _ =
      insert_enforcement!(%{
        user_id: platform_target.id,
        scope: "platform",
        action: "temporary_suspension",
        status: "active",
        starts_at: DateTime.add(now, -7200, :second),
        ends_at: DateTime.add(now, -60, :second)
      })

    _ =
      insert_enforcement!(%{
        user_id: rides_target.id,
        scope: "rides",
        action: "temporary_suspension",
        status: "active",
        starts_at: DateTime.add(now, -1200, :second),
        ends_at: DateTime.add(now, 1800, :second)
      })

    conn =
      get(
        auth_conn,
        "/api/moderation/enforcements/metrics?scope=platform&due_within_hours=24"
      )

    assert %{
             "data" => %{
               "summary" => %{
                 "active_total" => 3,
                 "due_within_hours" => 24,
                 "due_soon_temporary_suspensions" => 1,
                 "overdue_temporary_suspensions" => 1
               },
               "by_action_status" => groups
             }
           } = json_response(conn, 200)

    assert Enum.any?(groups, fn group ->
             group["action"] == "warning" and group["status"] == "active" and group["count"] == 1
           end)

    assert Enum.any?(groups, fn group ->
             group["action"] == "temporary_suspension" and group["status"] == "active" and
               group["count"] == 2
           end)
  end

  defp insert_enforcement!(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%UserEnforcement{
      user_id: attrs.user_id,
      scope: attrs.scope,
      action: attrs.action,
      status: attrs.status,
      starts_at: attrs.starts_at,
      ends_at: attrs.ends_at,
      inserted_at: now,
      updated_at: now,
      metadata: %{}
    })
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
