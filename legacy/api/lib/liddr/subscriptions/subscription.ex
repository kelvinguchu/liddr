defmodule Liddr.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending active grace expired cancelled)

  schema "subscriptions" do
    field :week_start, :date
    field :week_end, :date
    field :amount_kes, :decimal
    field :status, :string
    field :activated_at, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    field :driver_id, :id
    field :vehicle_category_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :driver_id,
      :vehicle_category_id,
      :week_start,
      :week_end,
      :amount_kes,
      :status,
      :activated_at,
      :expired_at
    ])
    |> validate_required([
      :driver_id,
      :vehicle_category_id,
      :week_start,
      :week_end,
      :amount_kes,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:driver_id)
    |> foreign_key_constraint(:vehicle_category_id)
    |> unique_constraint(:driver_id, name: :subscriptions_driver_id_week_start_week_end_index)
    |> check_constraint(:status, name: :subscriptions_status_valid)
    |> check_constraint(:week_end, name: :subscriptions_week_range_valid)
    |> check_constraint(:amount_kes, name: :subscriptions_amount_non_negative)
  end
end
