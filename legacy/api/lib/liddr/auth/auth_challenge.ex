defmodule Liddr.Auth.AuthChallenge do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(phone_otp email_otp email_password google apple totp)
  @purposes ~w(login register_driver register_rider step_up recover_account reset_password)
  @channels ~w(sms email totp push)

  schema "auth_challenges" do
    field :provider, :string
    field :identity_value, :string
    field :purpose, :string
    field :channel, :string
    field :code_hash, :string
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 5
    field :locked_until, :utc_datetime_usec
    field :requested_by_ip, :string
    field :requested_by_device, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(auth_challenge, attrs) do
    auth_challenge
    |> cast(attrs, [
      :user_id,
      :provider,
      :identity_value,
      :purpose,
      :channel,
      :code_hash,
      :expires_at,
      :consumed_at,
      :attempts,
      :max_attempts,
      :locked_until,
      :requested_by_ip,
      :requested_by_device,
      :metadata
    ])
    |> validate_required([
      :provider,
      :identity_value,
      :purpose,
      :channel,
      :code_hash,
      :expires_at
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:purpose, @purposes)
    |> validate_inclusion(:channel, @channels)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1)
  end
end
