defmodule LiddrWeb.RideOfferLockHealthControllerTest do
  use LiddrWeb.ConnCase, async: false

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

  test "GET /api/ops/rides/offer-lock/health requires auth", %{conn: conn} do
    conn = get(conn, "/api/ops/rides/offer-lock/health")
    assert %{"error" => %{"code" => "AUTH_REQUIRED"}} = json_response(conn, 401)
  end

  test "GET /api/ops/rides/offer-lock/health returns monitor snapshot", %{conn: _conn} do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-offer-lock-health@example.com")

    conn = get(ops_conn, "/api/ops/rides/offer-lock/health")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["monitor_enabled"] == false
    assert data["monitor_running"] == false

    assert data["fallback_allow_unavailable"] ==
             Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    assert data["window_ms"] == 60000
    assert data["min_attempts"] == 20
    assert data["unavailable_ratio_alert_threshold"] == 0.05
    assert data["last_alert"] == nil
    assert data["last_window"]["closed_at"] == nil
    assert data["last_window"]["alerts"] == []
    assert data["current_window"]["totals"]["attempts"] == 0
    assert data["current_window"]["totals"]["unavailable"] == 0
    assert data["current_window"]["totals"]["blocked"] == 0
    assert data["current_window"]["totals"]["unavailable_ratio"] == 0.0
    assert data["dispatch_blocking_risk"]["current_window_unavailable"] == 0
    assert data["dispatch_blocking_risk"]["last_window_unavailable"] == 0
    assert data["dispatch_blocking_risk"]["current_window_blocked"] == 0
    assert data["dispatch_blocking_risk"]["last_window_blocked"] == 0
    assert data["dispatch_blocking_risk"]["current_window_blocking_risk"] == false
    assert data["dispatch_blocking_risk"]["last_window_blocking_risk"] == false
    assert data["alert_recommendation"]["level"] == "ok"
    assert data["alert_recommendation"]["should_page"] == false
    assert data["alert_recommendation"]["code"] == "NONE"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
