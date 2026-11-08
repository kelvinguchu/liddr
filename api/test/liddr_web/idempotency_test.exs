defmodule LiddrWeb.IdempotencyTest do
  use LiddrWeb.ConnCase, async: false

  alias Liddr.Idempotency
  alias Liddr.Idempotency.Request
  alias Liddr.Repo
  alias Liddr.VerificationFixtures
  alias LiddrWeb.Idempotency, as: WebIdempotency

  @key "retry-key-123456"
  @operation "test.operation"

  test "a raised exception releases the key for a retry", %{conn: conn} do
    user = VerificationFixtures.create_user!()
    conn = conn |> assign(:current_user, user) |> put_req_header("idempotency-key", @key)

    assert_raise RuntimeError, "boom", fn ->
      WebIdempotency.execute(conn, @operation, %{}, fn -> raise "boom" end, &render_error/2)
    end

    response =
      WebIdempotency.execute(
        conn,
        @operation,
        %{},
        fn -> {:ok, 200, %{ok: true}} end,
        &render_error/2
      )

    assert %{"ok" => true} = json_response(response, 200)
  end

  test "an abandoned claim can be retaken after the stale window" do
    user = VerificationFixtures.create_user!()

    assert {:proceed, claim} = Idempotency.claim(user.id, @operation, @key, %{})
    assert {:error, :idempotency_in_progress} = Idempotency.claim(user.id, @operation, @key, %{})

    stale_at =
      DateTime.utc_now() |> DateTime.add(-301, :second) |> DateTime.truncate(:microsecond)

    Repo.get!(Request, claim.id)
    |> Ecto.Changeset.change(inserted_at: stale_at)
    |> Repo.update!()

    assert {:proceed, retaken} = Idempotency.claim(user.id, @operation, @key, %{})
    refute retaken.id == claim.id
  end

  test "a completed claim is replayed even when old" do
    user = VerificationFixtures.create_user!()
    {:proceed, claim} = Idempotency.claim(user.id, @operation, @key, %{})
    :ok = Idempotency.complete(claim, 200, %{ok: true})

    stale_at =
      DateTime.utc_now() |> DateTime.add(-301, :second) |> DateTime.truncate(:microsecond)

    Repo.get!(Request, claim.id)
    |> Ecto.Changeset.change(inserted_at: stale_at)
    |> Repo.update!()

    assert {:replay, %{status: 200}} = Idempotency.claim(user.id, @operation, @key, %{})
  end

  defp render_error(conn, _reason), do: Plug.Conn.send_resp(conn, 422, "")
end
