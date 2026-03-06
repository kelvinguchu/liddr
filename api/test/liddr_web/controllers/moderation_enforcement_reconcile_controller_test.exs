defmodule LiddrWeb.ModerationEnforcementReconcileControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation
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

  test "POST /api/moderation/enforcements/reconcile-expired requires auth", %{conn: conn} do
    conn = post(conn, "/api/moderation/enforcements/reconcile-expired", %{})

    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "POST /api/moderation/enforcements/reconcile-expired rejects invalid limit", %{conn: _conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_ops!("ops-reconcile-invalid@example.com")
    auth_conn = AuthFixtures.with_step_up!(auth_conn)

    conn = post(auth_conn, "/api/moderation/enforcements/reconcile-expired", %{"limit" => "0"})

    assert %{"error" => %{"code" => "INVALID_RECONCILIATION_LIMIT"}} = json_response(conn, 422)
  end

  test "POST /api/moderation/enforcements/reconcile-expired expires due temporary suspensions", %{
    conn: _conn
  } do
    %{auth_conn: auth_conn, user_id: actor_id} =
      AuthFixtures.authenticate_ops!("ops-reconcile-run@example.com")

    auth_conn = AuthFixtures.with_step_up!(auth_conn)

    target = Repo.insert!(%User{phone: VerificationFixtures.unique_phone()})

    {:ok, enforcement} =
      Moderation.apply_enforcement(%{
        "user_id" => target.id,
        "actor_user_id" => actor_id,
        "action" => "temporary_suspension",
        "reason_code" => "manual_reconcile_test",
        "ends_at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    mark_enforcement_due!(enforcement.id, now)

    conn =
      post(auth_conn, "/api/moderation/enforcements/reconcile-expired", %{
        "limit" => 10
      })

    assert %{
             "data" => %{
               "processed" => 1,
               "expired" => 1,
               "results" => [result]
             }
           } = json_response(conn, 200)

    assert result["enforcement_id"] == enforcement.id
    assert result["status"] == "expired"

    updated_enforcement = Repo.get!(UserEnforcement, enforcement.id)
    updated_user = Repo.get!(User, target.id)

    assert updated_enforcement.status == "expired"
    assert updated_user.account_status == "active"
  end

  defp mark_enforcement_due!(enforcement_id, now) do
    starts_at = DateTime.add(now, -3600, :second)
    ends_at = DateTime.add(now, -60, :second)

    {count, _} =
      Repo.update_all(
        from(ue in UserEnforcement, where: ue.id == ^enforcement_id),
        set: [starts_at: starts_at, ends_at: ends_at, updated_at: now]
      )

    assert count == 1
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
