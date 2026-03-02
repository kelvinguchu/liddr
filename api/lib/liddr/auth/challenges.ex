defmodule Liddr.Auth.Challenges do
  import Ecto.Query

  require Logger

  alias Liddr.Auth.AuthChallenge
  alias Liddr.Auth.AuthIdentity
  alias Liddr.Auth.Crypto
  alias Liddr.Auth.Identities
  alias Liddr.Auth.Input
  alias Liddr.Auth.Methods
  alias Liddr.Auth.Policy
  alias Liddr.Auth.Sessions
  alias Liddr.Repo

  @challenge_ttl_seconds 300
  @challenge_lock_seconds 300
  @challenge_cooldown_seconds 30

  def request_challenge(attrs, meta \\ %{}) do
    with {:ok, provider} <- Input.fetch_method(attrs),
         :ok <- Methods.ensure_otp_provider(provider),
         {:ok, purpose} <- Input.fetch_challenge_purpose(attrs),
         {:ok, identifier} <- Input.fetch_identifier(attrs),
         {:ok, normalized_identifier} <-
           Input.normalize_identifier_for_method(provider, identifier) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      with :ok <- enforce_challenge_cooldown(provider, normalized_identifier, purpose, now) do
        code = Crypto.generate_otp_code()
        maybe_log_debug_otp(provider, normalized_identifier, purpose, code)
        user = Identities.find_existing_user_by_identifier(Repo, provider, normalized_identifier)

        with :ok <- Policy.ensure_user_can_authenticate(user) do
          challenge_attrs = %{
            user_id: user && user.id,
            provider: provider,
            identity_value: normalized_identifier,
            purpose: purpose,
            channel: Methods.provider_to_channel(provider),
            code_hash: Crypto.otp_hash(code),
            expires_at: DateTime.add(now, @challenge_ttl_seconds, :second),
            max_attempts: 5,
            requested_by_ip: Input.get_value(meta, :ip),
            requested_by_device: Input.get_value(meta, :device),
            metadata: %{issued_for_method: provider}
          }

          case %AuthChallenge{}
               |> AuthChallenge.create_changeset(challenge_attrs)
               |> Repo.insert() do
            {:ok, challenge} ->
              {:ok,
               %{
                 challenge_id: challenge.id,
                 method: provider,
                 purpose: challenge.purpose,
                 channel: challenge.channel,
                 expires_at: challenge.expires_at,
                 debug_code: Crypto.maybe_debug_code(code, normalized_identifier)
               }}

            {:error, changeset} ->
              {:error, changeset}
          end
        end
      end
    end
  end

  def verify_challenge(attrs, meta \\ %{}) do
    with {:ok, challenge_id} <- Input.fetch_challenge_id(attrs),
         {:ok, code} <- Input.fetch_code(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        challenge =
          Repo.one(
            from ac in AuthChallenge,
              where: ac.id == ^challenge_id,
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(challenge) ->
            {:error, :challenge_not_found}

          true ->
            with :ok <- validate_challenge_state(challenge, now),
                 :ok <- validate_challenge_code(challenge, code, now),
                 {:ok, identity} <-
                   Identities.get_or_create_identity_for_challenge(
                     challenge.provider,
                     challenge.identity_value,
                     now
                   ),
                 {:ok, user} <- Policy.fetch_user(identity.user_id),
                 :ok <- Policy.ensure_user_can_authenticate(user),
                 {:ok, _updated_identity} <-
                   Repo.update(AuthIdentity.touch_last_used_changeset(identity, now)),
                 {:ok, _consumed_challenge} <-
                   Repo.update(
                     Ecto.Changeset.change(challenge, %{
                       consumed_at: now,
                       attempts: challenge.attempts + 1
                     })
                   ) do
              {:ok,
               Sessions.issue_session!(
                 identity.user_id,
                 identity.provider,
                 now,
                 %{
                   ip: Input.get_value(meta, :ip),
                   device: Input.get_value(meta, :device),
                   user_agent: Input.get_value(meta, :user_agent)
                 }
               )}
            end
        end
      end)
      |> case do
        {:ok, {:ok, session_payload}} -> {:ok, session_payload}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp enforce_challenge_cooldown(provider, identity_value, purpose, now) do
    cutoff = DateTime.add(now, -@challenge_cooldown_seconds, :second)

    recent =
      Repo.one(
        from ac in AuthChallenge,
          where:
            ac.provider == ^provider and ac.identity_value == ^identity_value and
              ac.purpose == ^purpose and
              ac.inserted_at >= ^cutoff
      )

    if recent, do: {:error, :challenge_rate_limited}, else: :ok
  end

  defp validate_challenge_state(challenge, now) do
    cond do
      not is_nil(challenge.consumed_at) ->
        {:error, :challenge_already_consumed}

      not is_nil(challenge.locked_until) and DateTime.compare(challenge.locked_until, now) == :gt ->
        {:error, :challenge_locked}

      DateTime.compare(challenge.expires_at, now) in [:lt, :eq] ->
        {:error, :challenge_expired}

      true ->
        :ok
    end
  end

  defp validate_challenge_code(challenge, code, now) do
    if challenge.code_hash == Crypto.otp_hash(code) do
      :ok
    else
      handle_failed_challenge_attempt(challenge, now)
    end
  end

  defp handle_failed_challenge_attempt(challenge, now) do
    new_attempts = challenge.attempts + 1

    locked_until =
      if new_attempts >= challenge.max_attempts do
        DateTime.add(now, @challenge_lock_seconds, :second)
      else
        nil
      end

    case Repo.update(
           Ecto.Changeset.change(challenge, %{attempts: new_attempts, locked_until: locked_until})
         ) do
      {:ok, _} when is_nil(locked_until) -> {:error, :invalid_code}
      {:ok, _} -> {:error, :challenge_locked}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_log_debug_otp(provider, identifier, purpose, code) do
    if not is_nil(Crypto.maybe_debug_code(code, identifier)) do
      Logger.warning(
        "[auth.otp] provider=#{provider} identifier=#{identifier} purpose=#{purpose} code=#{code}"
      )
    end
  end
end
