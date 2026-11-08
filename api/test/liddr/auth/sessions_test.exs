defmodule Liddr.Auth.SessionsTest do
  use Liddr.DataCase, async: true

  alias Liddr.Auth.AuthSession
  alias Liddr.Auth.Sessions
  alias Liddr.Repo
  alias Liddr.VerificationFixtures

  test "refresh token reuse revokes every session in the family" do
    %{first: first} = session_fixture()

    assert {:ok, rotated} = Sessions.refresh_session(%{"refresh_token" => first.refresh_token})

    assert {:error, :refresh_token_reuse_detected} =
             Sessions.refresh_session(%{"refresh_token" => first.refresh_token})

    assert Repo.get!(AuthSession, rotated.session_id).revoked_reason == "reuse_detected"

    assert {:error, :access_token_revoked} =
             Sessions.authenticate_access_token(rotated.access_token)

    assert {:error, :refresh_token_revoked} =
             Sessions.refresh_session(%{"refresh_token" => rotated.refresh_token})
  end

  test "using an access token on a restricted account revokes the session" do
    %{user: user, first: first} = session_fixture()
    suspend!(user)

    assert {:error, :account_suspended} = Sessions.authenticate_access_token(first.access_token)
    assert Repo.get!(AuthSession, first.session_id).revoked_reason == "account_restricted"
  end

  test "refreshing on a restricted account revokes the session" do
    %{user: user, first: first} = session_fixture()
    suspend!(user)

    assert {:error, :account_suspended} =
             Sessions.refresh_session(%{"refresh_token" => first.refresh_token})

    assert Repo.get!(AuthSession, first.session_id).revoked_reason == "account_restricted"
  end

  test "an expired refresh token is recorded as expired" do
    %{first: first} = session_fixture()

    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :minute) |> DateTime.truncate(:microsecond)

    Repo.get!(AuthSession, first.session_id)
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    assert {:error, :refresh_token_expired} =
             Sessions.refresh_session(%{"refresh_token" => first.refresh_token})

    assert Repo.get!(AuthSession, first.session_id).revoked_reason == "expired"
  end

  test "normal rotation still revokes only the replaced session" do
    %{first: first} = session_fixture()

    assert {:ok, rotated} = Sessions.refresh_session(%{"refresh_token" => first.refresh_token})

    assert Repo.get!(AuthSession, first.session_id).revoked_reason == "rotated"
    assert is_nil(Repo.get!(AuthSession, rotated.session_id).revoked_at)
    assert {:ok, _payload} = Sessions.authenticate_access_token(rotated.access_token)
  end

  test "a recent session is authenticated without rewriting last seen" do
    %{first: first} = session_fixture()
    seen_at = set_last_seen!(first.session_id, -10)

    assert {:ok, _payload} = Sessions.authenticate_access_token(first.access_token)
    assert DateTime.compare(Repo.get!(AuthSession, first.session_id).last_seen_at, seen_at) == :eq
  end

  test "last seen is refreshed once it is over a minute old" do
    %{first: first} = session_fixture()
    seen_at = set_last_seen!(first.session_id, -120)

    assert {:ok, _payload} = Sessions.authenticate_access_token(first.access_token)
    assert DateTime.compare(Repo.get!(AuthSession, first.session_id).last_seen_at, seen_at) == :gt
  end

  test "an unknown access token is rejected" do
    assert {:error, :invalid_access_token} = Sessions.authenticate_access_token("missing")
  end

  defp set_last_seen!(session_id, offset_seconds) do
    seen_at =
      DateTime.utc_now() |> DateTime.add(offset_seconds) |> DateTime.truncate(:microsecond)

    Repo.get!(AuthSession, session_id)
    |> Ecto.Changeset.change(last_seen_at: seen_at)
    |> Repo.update!()

    seen_at
  end

  defp session_fixture do
    user = VerificationFixtures.create_user!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{user: user, first: Sessions.issue_session!(user.id, "phone_otp", now, %{})}
  end

  defp suspend!(user) do
    user |> Ecto.Changeset.change(account_status: "suspended") |> Repo.update!()
  end
end
