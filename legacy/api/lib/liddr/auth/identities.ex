defmodule Liddr.Auth.Identities do
  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Auth.AuthIdentity
  alias Liddr.Repo

  def find_identity(repo, method, normalized_identifier) do
    identity =
      repo.one(
        from ai in AuthIdentity,
          where:
            ai.provider == ^method and ai.identifier_normalized == ^normalized_identifier and
              is_nil(ai.disabled_at),
          preload: [:user]
      )

    {:ok, identity}
  end

  def fetch_identity(provider, normalized_identifier) do
    Repo.one(
      from ai in AuthIdentity,
        where:
          ai.provider == ^provider and ai.identifier_normalized == ^normalized_identifier and
            is_nil(ai.disabled_at)
    )
  end

  def find_existing_user_by_identifier(repo, "phone_otp", normalized_identifier) do
    repo.one(from u in User, where: u.phone == ^normalized_identifier)
  end

  def find_existing_user_by_identifier(repo, method, normalized_identifier)
      when method in ["email_otp", "email_password", "totp"] do
    repo.one(from u in User, where: u.email == ^normalized_identifier)
  end

  def find_existing_user_by_identifier(repo, "google", normalized_identifier) do
    repo.one(from u in User, where: u.google_id == ^normalized_identifier)
  end

  def find_existing_user_by_identifier(_repo, _method, _normalized_identifier), do: nil

  def ensure_identity(
        repo,
        %AuthIdentity{} = identity,
        _user,
        _method,
        _identifier,
        _normalized_identifier,
        _secret_payload,
        now
      ) do
    identity
    |> AuthIdentity.touch_last_used_changeset(now)
    |> repo.update()
  end

  def ensure_identity(
        repo,
        nil,
        user,
        method,
        identifier,
        normalized_identifier,
        secret_payload,
        now
      ) do
    attrs =
      %{
        user_id: user.id,
        provider: method,
        identifier: identifier,
        identifier_normalized: normalized_identifier,
        secret_hash: secret_payload.secret_hash,
        secret_salt: secret_payload.secret_salt,
        last_used_at: now,
        verified_at: auto_verified_at(method, now)
      }
      |> add_identity_metadata(method)

    %AuthIdentity{}
    |> AuthIdentity.create_changeset(attrs)
    |> repo.insert()
  end

  def get_or_create_identity_for_challenge(provider, normalized_identifier, now) do
    case fetch_identity(provider, normalized_identifier) do
      %AuthIdentity{} = identity ->
        {:ok, identity}

      nil ->
        case find_existing_user_by_identifier(Repo, provider, normalized_identifier) do
          %User{} = user ->
            attrs = %{
              user_id: user.id,
              provider: provider,
              identifier: normalized_identifier,
              identifier_normalized: normalized_identifier,
              last_used_at: now
            }

            case %AuthIdentity{} |> AuthIdentity.create_changeset(attrs) |> Repo.insert() do
              {:ok, identity} -> {:ok, identity}
              {:error, changeset} -> {:error, changeset}
            end

          nil ->
            {:error, :identity_not_found}
        end
    end
  end

  defp auto_verified_at(method, now) when method in ["google", "apple"], do: now
  defp auto_verified_at(_method, _now), do: nil

  defp add_identity_metadata(attrs, "google"),
    do: Map.put(attrs, :metadata, %{trusted_provider: true})

  defp add_identity_metadata(attrs, "apple"),
    do: Map.put(attrs, :metadata, %{trusted_provider: true})

  defp add_identity_metadata(attrs, _), do: attrs
end
