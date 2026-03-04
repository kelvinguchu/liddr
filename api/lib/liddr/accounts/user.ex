defmodule Liddr.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @account_statuses ~w(active restricted suspended banned deactivated)
  @ride_booking_modes ~w(normal prepay_only)

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
    field :ride_booking_mode, :string
    field :ride_booking_mode_until, :utc_datetime_usec
    field :rating_score, :decimal
    field :rating_count, :integer
    field :rating_weighted_sum, :decimal
    field :rating_weight_total, :decimal

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

  def ride_booking_mode_changeset(user, attrs) do
    user
    |> cast(attrs, [:ride_booking_mode, :ride_booking_mode_until])
    |> validate_required([:ride_booking_mode])
    |> validate_inclusion(:ride_booking_mode, @ride_booking_modes)
    |> check_constraint(:ride_booking_mode, name: :users_ride_booking_mode_valid)
    |> check_constraint(:ride_booking_mode_until, name: :users_ride_booking_mode_until_required)
  end

  def rating_stats_changeset(user, attrs) do
    user
    |> cast(attrs, [:rating_score, :rating_count, :rating_weighted_sum, :rating_weight_total])
    |> validate_number(:rating_count, greater_than_or_equal_to: 0)
    |> check_constraint(:rating_score, name: :users_rating_score_range)
    |> check_constraint(:rating_count, name: :users_rating_count_non_negative)
    |> check_constraint(:rating_weight_total, name: :users_rating_weight_total_non_negative)
  end
end
