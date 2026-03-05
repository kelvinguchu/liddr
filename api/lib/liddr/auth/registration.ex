defmodule Liddr.Auth.Registration do
  import Ecto.Query

  alias Ecto.Multi
  alias Liddr.Accounts.User
  alias Liddr.Accounts.UserRole
  alias Liddr.Auth.Crypto
  alias Liddr.Auth.Google
  alias Liddr.Auth.Identities
  alias Liddr.Auth.Input
  alias Liddr.Auth.Methods
  alias Liddr.Auth.Policy
  alias Liddr.Repo

  @allowed_genders ~w(female male other unknown)

  def register_user(attrs, user_role) do
    with {:ok, method} <- Input.fetch_method(attrs),
         :ok <- Methods.method_allowed_for_role?(method, user_role),
         {:ok, profile_seed_attrs} <- extract_profile_seed_attrs(attrs),
         {:ok, identity} <- resolve_identity_for_method(method, attrs),
         {:ok, secret_payload} <- Crypto.build_secret_payload(method, attrs) do
      identifier = identity.identifier
      normalized_identifier = identity.normalized_identifier
      user_seed_attrs = Map.merge(identity.user_seed_attrs, profile_seed_attrs)

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Multi.new()
      |> Multi.run(:existing_identity, fn repo, _ ->
        Identities.find_identity(repo, method, normalized_identifier)
      end)
      |> Multi.run(:user, fn repo, %{existing_identity: existing_identity} ->
        get_or_create_user(
          repo,
          existing_identity,
          method,
          normalized_identifier,
          user_seed_attrs
        )
      end)
      |> Multi.run(:user_authz, fn _repo, %{user: user} ->
        case Policy.ensure_user_can_authenticate(user) do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end)
      |> Multi.run(:auth_identity, fn repo, %{existing_identity: existing_identity, user: user} ->
        Identities.ensure_identity(
          repo,
          existing_identity,
          user,
          method,
          identifier,
          normalized_identifier,
          secret_payload,
          now
        )
      end)
      |> Multi.run(:role, fn repo, %{user: user} ->
        ensure_user_role(repo, user.id, user_role, now)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user, role: role, auth_identity: identity}} ->
          {:ok,
           %{
             user_id: user.id,
             role: role.role,
             auth_method: identity.provider,
             identifier: identity.identifier_normalized,
             identity_verified: not is_nil(identity.verified_at)
           }}

        {:error, _step, {:error, reason}, _changes} ->
          {:error, reason}

        {:error, _step, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  defp get_or_create_user(
         _repo,
         %{user: %User{} = user},
         _method,
         _normalized_identifier,
         _user_seed_attrs
       ),
       do: {:ok, user}

  defp get_or_create_user(repo, nil, method, normalized_identifier, user_seed_attrs) do
    case Identities.find_existing_user_by_identifier(repo, method, normalized_identifier) do
      %User{} = user ->
        {:ok, user}

      nil ->
        user_attrs =
          %{
            phone: if(method == "phone_otp", do: normalized_identifier, else: nil),
            email:
              if(method in ["email_otp", "email_password", "totp"],
                do: normalized_identifier,
                else: nil
              )
          }
          |> Map.merge(user_seed_attrs)
          |> maybe_put_google_id(method, normalized_identifier)

        %User{}
        |> User.registration_changeset(user_attrs)
        |> repo.insert()
    end
  end

  defp maybe_put_google_id(attrs, "google", identifier),
    do: Map.put(attrs, :google_id, identifier)

  defp maybe_put_google_id(attrs, _method, _identifier), do: attrs

  defp resolve_identity_for_method("google", attrs) do
    id_token =
      attrs
      |> Input.get_value(:secret)
      |> Input.to_string_or_nil()

    with {:ok, claims} <- Google.verify_id_token(id_token) do
      {:ok,
       %{
         identifier: claims.subject,
         normalized_identifier: claims.subject,
         user_seed_attrs:
           if(claims.email_verified and is_binary(claims.email),
             do: %{email: claims.email},
             else: %{}
           )
       }}
    end
  end

  defp resolve_identity_for_method(method, attrs) do
    with {:ok, identifier} <- Input.fetch_identifier(attrs),
         {:ok, normalized_identifier} <- Input.normalize_identifier_for_method(method, identifier) do
      {:ok,
       %{
         identifier: identifier,
         normalized_identifier: normalized_identifier,
         user_seed_attrs: %{}
       }}
    end
  end

  defp ensure_user_role(repo, user_id, role, now) do
    existing_role =
      repo.one(
        from ur in UserRole,
          where: ur.user_id == ^user_id and ur.role == ^role and is_nil(ur.revoked_at)
      )

    if existing_role do
      {:ok, existing_role}
    else
      %UserRole{}
      |> UserRole.create_changeset(%{user_id: user_id, role: role, granted_at: now})
      |> repo.insert()
    end
  end

  defp extract_profile_seed_attrs(attrs) do
    gender =
      attrs
      |> Input.get_value(:gender)
      |> Input.to_string_or_nil()
      |> Input.normalize_text()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    if is_nil(gender) or gender in @allowed_genders do
      {:ok, if(is_nil(gender), do: %{}, else: %{gender: gender})}
    else
      {:error, :invalid_gender}
    end
  end
end
