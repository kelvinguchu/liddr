defmodule Liddr.Rides.VehicleCategory do
  use Ecto.Schema

  schema "vehicle_categories" do
    field :slug, :string
    field :label, :string
    field :capacity, :integer
    field :base_fee_kes, :decimal
    field :price_per_km_kes, :decimal
    field :price_per_min_kes, :decimal
    field :min_fare_kes, :decimal
    field :discount_percent, :decimal
    field :weekly_sub_kes, :integer
    field :is_active, :boolean

    timestamps(type: :utc_datetime_usec)
  end
end
