defmodule Liddr.Rides.UserPushToken do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(fcm)
  @platforms ~w(android ios web)

  schema "user_push_tokens" do
    field :user_id, :id
    field :provider, :string, default: "fcm"
    field :platform, :string
    field :token, :string
    field :device_id, :string
    field :last_seen_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(push_token, attrs) do
    push_token
    |> cast(attrs, [
      :user_id,
      :provider,
      :platform,
      :token,
      :device_id,
      :last_seen_at,
      :revoked_at,
      :metadata
    ])
    |> validate_required([:user_id, :provider, :platform, :token, :last_seen_at])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:platform, @platforms)
    |> validate_length(:token, min: 8, max: 4096)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token, name: :user_push_tokens_token_unique)
    |> check_constraint(:provider, name: :user_push_tokens_provider_valid)
    |> check_constraint(:platform, name: :user_push_tokens_platform_valid)
    |> check_constraint(:token, name: :user_push_tokens_token_non_empty)
  end
end
