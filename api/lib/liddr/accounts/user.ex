defmodule Liddr.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @account_statuses ~w(active restricted suspended banned deactivated)

  schema "users" do
    field :phone, :string
    field :google_id, :string
    field :email, :string
    field :phone_verified_at, :utc_datetime_usec
    field :email_verified_at, :utc_datetime_usec
    field :account_status, :string
    field :account_status_reason_code, :string
    field :account_restricted_at, :utc_datetime_usec
    field :account_restricted_until, :utc_datetime_usec
    field :account_banned_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:phone, :google_id, :email, :phone_verified_at, :email_verified_at])
    |> unique_constraint(:phone)
    |> unique_constraint(:google_id)
    |> unique_constraint(:email)
  end

  def account_status_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :account_status,
      :account_status_reason_code,
      :account_restricted_at,
      :account_restricted_until,
      :account_banned_at
    ])
    |> validate_required([:account_status])
    |> validate_inclusion(:account_status, @account_statuses)
  end
end
