defmodule Liddr.Auth.AuthSession do
  use Ecto.Schema
  import Ecto.Changeset

  @auth_methods ~w(phone_otp email_otp email_password google apple totp step_up)

  schema "auth_sessions" do
    field :session_family_id, Ecto.UUID
    field :session_token_hash, :string
    field :refresh_token_hash, :string
    field :auth_method, :string
    field :issued_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string
    field :issued_by_ip, :string
    field :issued_by_device, :string
    field :issued_by_user_agent, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Liddr.Accounts.User
    belongs_to :replaced_by_session, __MODULE__

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(auth_session, attrs) do
    auth_session
    |> cast(attrs, [
      :user_id,
      :session_family_id,
      :session_token_hash,
      :refresh_token_hash,
      :auth_method,
      :issued_at,
      :last_seen_at,
      :expires_at,
      :revoked_at,
      :revoked_reason,
      :replaced_by_session_id,
      :issued_by_ip,
      :issued_by_device,
      :issued_by_user_agent,
      :metadata
    ])
    |> validate_required([
      :user_id,
      :session_family_id,
      :session_token_hash,
      :refresh_token_hash,
      :auth_method,
      :issued_at,
      :expires_at
    ])
    |> validate_inclusion(:auth_method, @auth_methods)
    |> unique_constraint(:session_token_hash)
    |> unique_constraint(:refresh_token_hash)
  end
end
