defmodule Liddr.Accounts.Driver do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:user_id, :id, autogenerate: false}
  @foreign_key_type :id

  @subscription_statuses ~w(inactive active grace suspended)
  @account_statuses ~w(pending active suspended deactivated)
  @verification_statuses ~w(unverified pending under_review approved rejected suspended)

  schema "drivers" do
    field :license_no, :string
    field :plate_no, :string
    field :vehicle_category_id, :id
    field :vehicle_year, :integer
    field :subscription_status, :string
    field :is_available, :boolean
    field :gender_verified, :boolean
    field :account_status, :string
    field :verification_status, :string
    field :last_seen_at, :utc_datetime_usec
    field :last_online_at, :utc_datetime_usec
    field :activated_at, :utc_datetime_usec
    field :suspended_at, :utc_datetime_usec

    belongs_to :user, Liddr.Accounts.User, define_field: false

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(driver, attrs) do
    driver
    |> cast(attrs, [
      :user_id,
      :license_no,
      :plate_no,
      :vehicle_category_id,
      :vehicle_year,
      :subscription_status,
      :is_available,
      :gender_verified,
      :account_status,
      :verification_status,
      :last_seen_at,
      :last_online_at,
      :activated_at,
      :suspended_at
    ])
    |> validate_required([:user_id, :vehicle_category_id, :subscription_status])
    |> validate_inclusion(:subscription_status, @subscription_statuses)
    |> validate_inclusion(:account_status, @account_statuses)
    |> validate_inclusion(:verification_status, @verification_statuses)
    |> unique_constraint(:plate_no)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:vehicle_category_id)
    |> check_constraint(:subscription_status, name: :drivers_subscription_status_valid)
    |> check_constraint(:account_status, name: :drivers_account_status_valid)
    |> check_constraint(:verification_status, name: :drivers_verification_status_valid)
    |> check_constraint(:vehicle_year, name: :drivers_vehicle_year_range)
  end
end
