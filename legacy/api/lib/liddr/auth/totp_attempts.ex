defmodule Liddr.Auth.TotpAttempts do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Liddr.Auth.AuthIdentity
  alias Liddr.Auth.Totp
  alias Liddr.Repo

  @max_failed_attempts 5
  @lock_seconds 300
  @failed_attempts_key "totp_failed_attempts"
  @locked_until_key "totp_locked_until"
  @last_counter_key "totp_last_counter"

  def verify(user_id, identity_id, code, now, fetch_secret) when is_integer(identity_id) do
    Repo.transaction(fn ->
      case lock_active_identity(user_id, identity_id) do
        nil -> {:error, :totp_not_enrolled}
        identity -> check_code(identity, code, now, fetch_secret)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_user_id, _identity_id, _code, _now, _fetch_secret),
    do: {:error, :totp_not_enrolled}

  defp lock_active_identity(user_id, identity_id) do
    Repo.one(
      from ai in AuthIdentity,
        where:
          ai.id == ^identity_id and ai.user_id == ^user_id and ai.provider == "totp" and
            is_nil(ai.disabled_at),
        lock: "FOR UPDATE"
    )
  end

  defp check_code(identity, code, now, fetch_secret) do
    metadata = identity.metadata || %{}

    if locked?(metadata, now) do
      {:error, :challenge_locked}
    else
      with {:ok, secret} <- fetch_secret.(identity) do
        secret
        |> fresh_counter(code, now, metadata)
        |> record_result(identity, metadata, now)
      end
    end
  end

  defp fresh_counter(secret, code, now, metadata) do
    with {:ok, counter} <- Totp.matching_counter(secret, code, now) do
      if counter > last_counter(metadata), do: {:ok, counter}, else: {:error, :invalid_totp_code}
    end
  end

  defp record_result({:ok, counter}, identity, metadata, now) do
    updated_metadata =
      metadata
      |> Map.drop([@failed_attempts_key, @locked_until_key])
      |> Map.put(@last_counter_key, counter)

    case update_identity(identity, %{metadata: updated_metadata, last_used_at: now}) do
      {:ok, _identity} -> {:ok, :verified}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp record_result({:error, :invalid_totp_code}, identity, metadata, now) do
    failed_attempts = failed_attempts(metadata) + 1

    {updated_metadata, error} =
      if failed_attempts >= @max_failed_attempts do
        {lock_metadata(metadata, now), :challenge_locked}
      else
        {Map.put(metadata, @failed_attempts_key, failed_attempts), :invalid_totp_code}
      end

    case update_identity(identity, %{metadata: updated_metadata}) do
      {:ok, _identity} -> {:error, error}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp record_result({:error, reason}, _identity, _metadata, _now), do: {:error, reason}

  defp lock_metadata(metadata, now) do
    locked_until = now |> DateTime.add(@lock_seconds, :second) |> DateTime.to_iso8601()

    metadata
    |> Map.delete(@failed_attempts_key)
    |> Map.put(@locked_until_key, locked_until)
  end

  defp update_identity(identity, changes) do
    identity
    |> Changeset.change(changes)
    |> Repo.update()
  end

  defp locked?(metadata, now) do
    with value when is_binary(value) <- Map.get(metadata, @locked_until_key),
         {:ok, locked_until, _offset} <- DateTime.from_iso8601(value) do
      DateTime.compare(locked_until, now) == :gt
    else
      _ -> false
    end
  end

  defp failed_attempts(metadata), do: integer_value(metadata, @failed_attempts_key, 0)
  defp last_counter(metadata), do: integer_value(metadata, @last_counter_key, -1)

  defp integer_value(metadata, key, default) do
    case Map.get(metadata, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end
end
