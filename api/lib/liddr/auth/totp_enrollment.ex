defmodule Liddr.Auth.TotpEnrollment do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Liddr.Accounts.User
  alias Liddr.Auth.AuthIdentity
  alias Liddr.Auth.Crypto
  alias Liddr.Auth.Input
  alias Liddr.Auth.Totp
  alias Liddr.Auth.TotpAttempts
  alias Liddr.Repo

  @setup_salt "auth_totp_setup"
  @step_up_salt "auth_totp_step_up"

  def request_setup(%User{} = user, session_id) do
    with {:ok, account_name} <- fetch_account_name(user),
         {:ok, setup_token} <- issue_setup_token(user.id, session_id, account_name) do
      secret = current_secret_from_token!(setup_token)

      {:ok,
       %{
         provider: "totp",
         setup_token: setup_token,
         secret: secret,
         issuer: Totp.issuer(),
         account_name: account_name,
         otpauth_uri: Totp.provisioning_uri(secret, account_name),
         expires_in: Totp.setup_ttl_seconds()
       }}
    end
  end

  def confirm_setup(%User{} = user, session_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, setup_token} <- fetch_setup_token(attrs),
         {:ok, code} <- Input.fetch_code(attrs),
         {:ok, payload} <- Totp.decrypt_payload(setup_token, @setup_salt),
         :ok <- validate_setup_payload(payload, user.id, session_id),
         :ok <- Totp.verify_code(payload["secret"], code, now),
         {:ok, _identity} <- upsert_identity(user, payload["secret"], now) do
      {:ok, %{provider: "totp", enrolled_at: now, issuer: Totp.issuer()}}
    end
  end

  def request_step_up_challenge(%User{} = user, session_id) do
    with %AuthIdentity{} = identity <- active_identity(user.id),
         {:ok, token} <- issue_step_up_token(user.id, session_id, identity.id) do
      expires_at = DateTime.utc_now() |> DateTime.add(Liddr.Auth.StepUp.ttl_seconds(), :second)

      {:ok,
       %{
         challenge_id: "totp:" <> token,
         method: "totp",
         purpose: "step_up",
         channel: "totp",
         expires_at: expires_at
       }}
    else
      nil -> {:error, :totp_not_enrolled}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_step_up_challenge(%User{} = user, session_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, token} <- fetch_totp_challenge_token(attrs),
         {:ok, code} <- Input.fetch_code(attrs),
         {:ok, payload} <- Totp.decrypt_payload(token, @step_up_salt),
         :ok <- validate_step_up_payload(payload, user.id, session_id) do
      TotpAttempts.verify(user.id, payload["identity_id"], code, now, &fetch_identity_secret/1)
    end
  end

  def active_identity(user_id) do
    Repo.one(
      from ai in AuthIdentity,
        where: ai.user_id == ^user_id and ai.provider == "totp" and is_nil(ai.disabled_at)
    )
  end

  defp issue_setup_token(user_id, session_id, account_name) do
    issued_at = DateTime.utc_now() |> DateTime.to_unix(:second)

    Totp.encrypt_payload(
      %{
        "type" => "totp_setup",
        "user_id" => user_id,
        "session_id" => session_id,
        "secret" => Totp.generate_secret(),
        "account_name" => account_name,
        "issued_at" => issued_at
      },
      @setup_salt
    )
  end

  defp issue_step_up_token(user_id, session_id, identity_id) do
    issued_at = DateTime.utc_now() |> DateTime.to_unix(:second)

    Totp.encrypt_payload(
      %{
        "type" => "totp_step_up",
        "user_id" => user_id,
        "session_id" => session_id,
        "identity_id" => identity_id,
        "issued_at" => issued_at
      },
      @step_up_salt
    )
  end

  defp upsert_identity(%User{} = user, secret, now) do
    encrypted_secret = encrypt_identity_secret(secret)
    identity = active_identity(user.id)

    attrs = %{
      identifier: user.email,
      identifier_normalized: user.email,
      secret_hash: Crypto.token_hash(secret),
      secret_salt: nil,
      verified_at: now,
      disabled_at: nil,
      last_used_at: now,
      metadata: %{"encrypted_secret" => encrypted_secret, "issuer" => Totp.issuer()}
    }

    case identity do
      %AuthIdentity{} = current_identity ->
        current_identity
        |> Changeset.change(attrs)
        |> Repo.update()

      nil ->
        %AuthIdentity{}
        |> AuthIdentity.create_changeset(
          Map.put(attrs, :user_id, user.id)
          |> Map.put(:provider, "totp")
        )
        |> Repo.insert()
    end
  end

  defp fetch_identity_secret(%AuthIdentity{metadata: metadata}) do
    encrypted_secret =
      Map.get(metadata || %{}, "encrypted_secret") || Map.get(metadata || %{}, :encrypted_secret)

    case Totp.decrypt_payload(encrypted_secret || "", @setup_salt <> "_identity") do
      {:ok, %{"secret" => secret}} -> {:ok, secret}
      _ -> {:error, :totp_secret_unavailable}
    end
  end

  defp encrypt_identity_secret(secret) do
    {:ok, token} = Totp.encrypt_payload(%{"secret" => secret}, @setup_salt <> "_identity")
    token
  end

  defp current_secret_from_token!(setup_token) do
    {:ok, %{"secret" => secret}} = Totp.decrypt_payload(setup_token, @setup_salt)

    secret
  end

  defp fetch_account_name(%User{email: email}) do
    case Input.normalize_text(email) do
      nil -> {:error, :totp_email_required}
      normalized -> {:ok, normalized}
    end
  end

  defp fetch_setup_token(attrs) do
    attrs
    |> Input.get_value(:setup_token)
    |> Input.to_string_or_nil()
    |> Input.normalize_text()
    |> case do
      nil -> {:error, :missing_setup_token}
      token -> {:ok, token}
    end
  end

  defp fetch_totp_challenge_token(attrs) do
    case Input.fetch_challenge_id(attrs) do
      {:ok, "totp:" <> token} -> {:ok, token}
      {:ok, _other} -> {:error, :not_totp_challenge}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_setup_payload(payload, expected_user_id, expected_session_id) do
    validate_bound_payload(payload, "totp_setup", expected_user_id, expected_session_id)
  end

  defp validate_step_up_payload(payload, expected_user_id, expected_session_id) do
    validate_bound_payload(payload, "totp_step_up", expected_user_id, expected_session_id)
  end

  defp validate_bound_payload(payload, expected_type, expected_user_id, expected_session_id) do
    cond do
      payload["type"] != expected_type -> {:error, :invalid_totp_token}
      payload["user_id"] != expected_user_id -> {:error, :totp_session_mismatch}
      payload["session_id"] != expected_session_id -> {:error, :totp_session_mismatch}
      token_expired?(payload, expected_type) -> {:error, :invalid_totp_token}
      true -> :ok
    end
  end

  defp token_expired?(payload, "totp_setup") do
    token_age_seconds(payload) > Totp.setup_ttl_seconds()
  end

  defp token_expired?(payload, "totp_step_up") do
    token_age_seconds(payload) > Liddr.Auth.StepUp.ttl_seconds()
  end

  defp token_expired?(_payload, _type), do: true

  defp token_age_seconds(%{"issued_at" => issued_at}) when is_integer(issued_at) do
    max((DateTime.utc_now() |> DateTime.to_unix(:second)) - issued_at, 0)
  end

  defp token_age_seconds(_payload), do: 86_400
end
