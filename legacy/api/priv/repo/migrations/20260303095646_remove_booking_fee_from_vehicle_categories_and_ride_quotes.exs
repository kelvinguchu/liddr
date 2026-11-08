defmodule Liddr.Repo.Migrations.RemoveBookingFeeFromVehicleCategoriesAndRideQuotes do
  use Ecto.Migration

  def up do
    drop constraint(:vehicle_categories, :vehicle_categories_booking_fee_non_negative)
    drop constraint(:ride_quotes, :ride_quotes_money_non_negative)

    alter table(:vehicle_categories) do
      remove :booking_fee_kes
    end

    alter table(:ride_quotes) do
      remove :booking_fee_kes
    end

    create constraint(:ride_quotes, :ride_quotes_money_non_negative,
             check:
               "base_amount_kes >= 0 AND distance_amount_kes >= 0 AND time_amount_kes >= 0 AND min_fare_kes >= 0 AND subtotal_kes >= 0 AND final_fare_kes >= 0"
           )
  end

  def down do
    drop constraint(:ride_quotes, :ride_quotes_money_non_negative)

    alter table(:vehicle_categories) do
      add :booking_fee_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
    end

    alter table(:ride_quotes) do
      add :booking_fee_kes, :decimal, precision: 10, scale: 2, null: false, default: 0
    end

    create constraint(:vehicle_categories, :vehicle_categories_booking_fee_non_negative,
             check: "booking_fee_kes >= 0"
           )

    create constraint(:ride_quotes, :ride_quotes_money_non_negative,
             check:
               "base_amount_kes >= 0 AND distance_amount_kes >= 0 AND time_amount_kes >= 0 AND booking_fee_kes >= 0 AND min_fare_kes >= 0 AND subtotal_kes >= 0 AND final_fare_kes >= 0"
           )
  end
end
