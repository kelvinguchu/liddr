defmodule Liddr.Repo.Migrations.AddFareComponentsToVehicleCategories do
  use Ecto.Migration

  def change do
    alter table(:vehicle_categories) do
      add :min_fare_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
      add :price_per_min_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
      add :booking_fee_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
    end

    create constraint(:vehicle_categories, :vehicle_categories_min_fare_non_negative,
             check: "min_fare_kes >= 0"
           )

    create constraint(:vehicle_categories, :vehicle_categories_price_per_min_non_negative,
             check: "price_per_min_kes >= 0"
           )

    create constraint(:vehicle_categories, :vehicle_categories_booking_fee_non_negative,
             check: "booking_fee_kes >= 0"
           )
  end
end
