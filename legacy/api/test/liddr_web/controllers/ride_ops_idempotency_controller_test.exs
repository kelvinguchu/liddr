defmodule LiddrWeb.RideOpsIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
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

  test "POST /api/ops/rides/integrity/reconcile-prepay-modes replays for identical key", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn} = AuthFixtures.authenticate_ops!("ops-ride-idempotency@example.com")
    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    user_one = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})
    user_two = Repo.insert!(%User{phone: AuthFixtures.unique_phone()})

    set_prepay_only!(user_one.id, DateTime.add(now, -60, :second))
    set_prepay_only!(user_two.id, DateTime.add(now, -120, :second))
    key = "ops-ride-reconcile-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/rides/integrity/reconcile-prepay-modes", %{"limit" => 1})
      |> json_response(200)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/ops/rides/integrity/reconcile-prepay-modes", %{"limit" => 1})
      |> json_response(200)

    assert first == second
    assert get_in(first, ["data", "processed"]) == 1

    remaining_prepay_count =
      Repo.one!(
        from u in User,
          where: u.id in ^[user_one.id, user_two.id] and u.ride_booking_mode == "prepay_only",
          select: count(u.id)
      )

    assert remaining_prepay_count == 1
  end

  defp set_prepay_only!(user_id, mode_until) do
    user = Repo.get!(User, user_id)

    user
    |> User.ride_booking_mode_changeset(%{
      "ride_booking_mode" => "prepay_only",
      "ride_booking_mode_until" => mode_until
    })
    |> Repo.update!()
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
