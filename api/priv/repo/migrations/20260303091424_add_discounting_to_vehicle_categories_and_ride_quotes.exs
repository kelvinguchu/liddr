defmodule Liddr.Repo.Migrations.AddDiscountingToVehicleCategoriesAndRideQuotes do
  use Ecto.Migration

  def up do
    alter table(:vehicle_categories) do
      add :discount_percent, :decimal, precision: 5, scale: 2, null: false, default: 0
    end

    create constraint(:vehicle_categories, :vehicle_categories_discount_percent_range,
             check: "discount_percent >= 0 AND discount_percent <= 100"
           )

    execute("""
    UPDATE vehicle_categories
    SET discount_percent = 10.00, updated_at = NOW()
    WHERE is_active = true
    """)

    alter table(:ride_quotes) do
      add :base_fare_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
      add :discount_percent, :decimal, precision: 5, scale: 2, null: false, default: 0
      add :discount_amount_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
    end

    execute("""
    UPDATE ride_quotes
    SET
      base_fare_kes = final_fare_kes,
      discount_percent = 0,
      discount_amount_kes = 0
    """)

    create constraint(:ride_quotes, :ride_quotes_discount_percent_range,
             check: "discount_percent >= 0 AND discount_percent <= 100"
           )

    create constraint(:ride_quotes, :ride_quotes_discount_amount_non_negative,
             check: "discount_amount_kes >= 0"
           )

    create constraint(:ride_quotes, :ride_quotes_base_fare_non_negative,
             check: "base_fare_kes >= 0"
           )
  end

  def down do
    drop constraint(:ride_quotes, :ride_quotes_base_fare_non_negative)
    drop constraint(:ride_quotes, :ride_quotes_discount_amount_non_negative)
    drop constraint(:ride_quotes, :ride_quotes_discount_percent_range)

    alter table(:ride_quotes) do
      remove :discount_amount_kes
      remove :discount_percent
      remove :base_fare_kes
    end

    drop constraint(:vehicle_categories, :vehicle_categories_discount_percent_range)

    alter table(:vehicle_categories) do
      remove :discount_percent
    end
  end
end
