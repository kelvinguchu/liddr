defmodule Liddr.Auth.AuthIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(phone_otp email_otp email_password google apple totp)

  schema "auth_identities" do
    field :provider, :string
    field :identifier, :string
    field :identifier_normalized, :string
    field :secret_hash, :string
    field :secret_salt, :string
    field :verified_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(auth_identity, attrs) do
    auth_identity
    |> cast(attrs, [
      :user_id,
      :provider,
      :identifier,
      :identifier_normalized,
      :secret_hash,
      :secret_salt,
      :verified_at,
      :disabled_at,
      :last_used_at,
      :metadata
    ])
    |> validate_required([:user_id, :provider, :identifier, :identifier_normalized])
    |> validate_inclusion(:provider, @providers)
    |> validate_secret_for_provider()
    |> unique_constraint(:identifier_normalized,
      name: :auth_identities_provider_identifier_normalized_index
    )
  end

  def touch_last_used_changeset(auth_identity, now) do
    auth_identity
    |> cast(%{last_used_at: now}, [:last_used_at])
    |> validate_required([:last_used_at])
  end

  defp validate_secret_for_provider(changeset) do
    provider = get_field(changeset, :provider)
    secret_hash = get_field(changeset, :secret_hash)

    if provider in ~w(email_password totp) and is_nil(secret_hash) do
      add_error(changeset, :secret_hash, "is required for provider #{provider}")
    else
      changeset
    end
  end
end
