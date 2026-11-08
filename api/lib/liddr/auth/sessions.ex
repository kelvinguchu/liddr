defmodule Liddr.Auth.Sessions do
  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Auth.AuthSession
  alias Liddr.Auth.Crypto
  alias Liddr.Auth.Input
  alias Liddr.Auth.Policy
  alias Liddr.Repo

  def authenticate_access_token(access_token, _meta \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    session_hash = Crypto.token_hash(access_token)

    Repo.transaction(fn ->
      session =
        Repo.one(
          from s in AuthSession,
            where: s.session_token_hash == ^session_hash,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:invalid_access_token)

      cond do
        not is_nil(session.revoked_at) ->
          Repo.rollback(:access_token_revoked)

        DateTime.compare(
          DateTime.add(session.issued_at, Crypto.access_ttl_seconds(), :second),
          now
        ) in [
          :lt,
          :eq
        ] ->
          Repo.rollback(:access_token_expired)

        true ->
          user = Repo.get(User, session.user_id) || Repo.rollback(:user_not_found)

          case Policy.ensure_user_can_authenticate(user) do
            :ok ->
              updated_session =
                Repo.update!(
                  Ecto.Changeset.change(session, %{
                    last_seen_at: now
                  })
                )

              %{
                user: user,
                session_id: updated_session.id,
                auth_method: updated_session.auth_method
              }

            {:error, reason} ->
              revoke_and_fail(session, now, "account_restricted", reason)
          end
      end
    end)
    |> unwrap_session_result()
  end

  def refresh_session(attrs, meta \\ %{}) do
    with {:ok, refresh_token} <- Input.fetch_refresh_token(attrs) do
      refresh_hash = Crypto.token_hash(refresh_token)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        session =
          Repo.one(
            from s in AuthSession,
              where: s.refresh_token_hash == ^refresh_hash,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:invalid_refresh_token)

        cond do
          not is_nil(session.revoked_at) and session.revoked_reason == "rotated" ->
            revoke_and_fail(session, now, "reuse_detected", :refresh_token_reuse_detected)

          not is_nil(session.revoked_at) ->
            Repo.rollback(:refresh_token_revoked)

          DateTime.compare(session.expires_at, now) in [:lt, :eq] ->
            Repo.update!(
              Ecto.Changeset.change(session, %{revoked_at: now, revoked_reason: "expired"})
            )

            {:commit_error, :refresh_token_expired}

          true ->
            user = Repo.get(User, session.user_id) || Repo.rollback(:user_not_found)

            case Policy.ensure_user_can_authenticate(user) do
              :ok -> rotate_session!(session, now, meta)
              {:error, reason} -> revoke_and_fail(session, now, "account_restricted", reason)
            end
        end
      end)
      |> unwrap_session_result()
    end
  end

  def logout(attrs) do
    with {:ok, refresh_token} <- Input.fetch_refresh_token(attrs) do
      refresh_hash = Crypto.token_hash(refresh_token)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      case Repo.get_by(AuthSession, refresh_token_hash: refresh_hash) do
        nil ->
          {:error, :session_not_found}

        %AuthSession{} = session when not is_nil(session.revoked_at) ->
          {:ok, %{revoked: false, reason: "already_revoked"}}

        %AuthSession{} = session ->
          session
          |> Ecto.Changeset.change(%{revoked_at: now, revoked_reason: "logout"})
          |> Repo.update()
          |> case do
            {:ok, _} -> {:ok, %{revoked: true}}
            {:error, changeset} -> {:error, changeset}
          end
      end
    end
  end

  def issue_session!(user_id, auth_method, now, meta, session_family_id \\ nil) do
    access_token = Crypto.token_value()
    refresh_token = Crypto.token_value()
    family_id = session_family_id || Ecto.UUID.generate()

    attrs = %{
      user_id: user_id,
      session_family_id: family_id,
      session_token_hash: Crypto.token_hash(access_token),
      refresh_token_hash: Crypto.token_hash(refresh_token),
      auth_method: auth_method,
      issued_at: now,
      last_seen_at: now,
      expires_at: DateTime.add(now, Crypto.refresh_ttl_seconds(), :second),
      issued_by_ip: Input.get_value(meta, :ip),
      issued_by_device: Input.get_value(meta, :device),
      issued_by_user_agent: Input.get_value(meta, :user_agent)
    }

    session =
      %AuthSession{}
      |> AuthSession.create_changeset(attrs)
      |> Repo.insert!()

    %{
      token_type: "bearer",
      access_token: access_token,
      access_token_expires_in: Crypto.access_ttl_seconds(),
      refresh_token: refresh_token,
      refresh_token_expires_in: Crypto.refresh_ttl_seconds(),
      session_id: session.id
    }
  end

  defp rotate_session!(session, now, meta) do
    new_session_payload =
      issue_session!(
        session.user_id,
        session.auth_method,
        now,
        %{
          ip: Input.get_value(meta, :ip),
          device: Input.get_value(meta, :device),
          user_agent: Input.get_value(meta, :user_agent)
        },
        session.session_family_id
      )

    replacement =
      Repo.get_by!(AuthSession,
        refresh_token_hash: Crypto.token_hash(new_session_payload.refresh_token)
      )

    Repo.update!(
      Ecto.Changeset.change(session, %{
        revoked_at: now,
        revoked_reason: "rotated",
        replaced_by_session_id: replacement.id
      })
    )

    new_session_payload
  end

  # Returning a value commits the transaction; Repo.rollback/1 would undo the revocation.
  defp revoke_and_fail(session, now, revoked_reason, error_reason) do
    revoke_family!(session.session_family_id, now, revoked_reason)
    {:commit_error, error_reason}
  end

  defp unwrap_session_result({:ok, {:commit_error, reason}}), do: {:error, reason}
  defp unwrap_session_result({:ok, payload}), do: {:ok, payload}
  defp unwrap_session_result({:error, reason}), do: {:error, reason}

  def revoke_family!(session_family_id, now, reason) do
    Repo.update_all(
      from(s in AuthSession,
        where: s.session_family_id == ^session_family_id and is_nil(s.revoked_at)
      ),
      set: [revoked_at: now, revoked_reason: reason]
    )
  end
end
