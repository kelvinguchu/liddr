defmodule Liddr.Repo.Migrations.UpdateVehicleCategoryPricingBaseline do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 20.00,
      booking_fee_kes = 10.00,
      price_per_km_kes = 15.00,
      price_per_min_kes = 3.00,
      min_fare_kes = 100.00,
      updated_at = NOW()
    WHERE slug = 'motorbike'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 65.00,
      booking_fee_kes = 30.00,
      price_per_km_kes = 33.00,
      price_per_min_kes = 7.00,
      min_fare_kes = 230.00,
      updated_at = NOW()
    WHERE slug = 'electric_motorbike'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 60.00,
      booking_fee_kes = 25.00,
      price_per_km_kes = 32.00,
      price_per_min_kes = 6.00,
      min_fare_kes = 200.00,
      updated_at = NOW()
    WHERE slug = 'basic'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 25.00,
      booking_fee_kes = 15.00,
      price_per_km_kes = 16.00,
      price_per_min_kes = 3.00,
      min_fare_kes = 110.00,
      updated_at = NOW()
    WHERE slug = 'send'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 95.00,
      booking_fee_kes = 40.00,
      price_per_km_kes = 42.00,
      price_per_min_kes = 11.00,
      min_fare_kes = 320.00,
      updated_at = NOW()
    WHERE slug = 'comfort'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 180.00,
      booking_fee_kes = 60.00,
      price_per_km_kes = 70.00,
      price_per_min_kes = 22.00,
      min_fare_kes = 660.00,
      updated_at = NOW()
    WHERE slug = 'xl'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 62.00,
      booking_fee_kes = 28.00,
      price_per_km_kes = 32.00,
      price_per_min_kes = 6.00,
      min_fare_kes = 210.00,
      updated_at = NOW()
    WHERE slug = 'women_only'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 60.00,
      booking_fee_kes = 25.00,
      price_per_km_kes = 31.00,
      price_per_min_kes = 6.00,
      min_fare_kes = 200.00,
      updated_at = NOW()
    WHERE slug = 'green'
    """)
  end

  def down do
    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 10.00,
      booking_fee_kes = 2.00,
      price_per_km_kes = 5.00,
      price_per_min_kes = 1.00,
      min_fare_kes = 10.00,
      updated_at = NOW()
    WHERE slug = 'motorbike'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 12.00,
      booking_fee_kes = 3.00,
      price_per_km_kes = 6.00,
      price_per_min_kes = 1.00,
      min_fare_kes = 15.00,
      updated_at = NOW()
    WHERE slug = 'electric_motorbike'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 14.00,
      booking_fee_kes = 4.00,
      price_per_km_kes = 7.00,
      price_per_min_kes = 2.00,
      min_fare_kes = 20.00,
      updated_at = NOW()
    WHERE slug = 'basic'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 10.00,
      booking_fee_kes = 2.00,
      price_per_km_kes = 5.00,
      price_per_min_kes = 1.00,
      min_fare_kes = 15.00,
      updated_at = NOW()
    WHERE slug = 'send'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 18.00,
      booking_fee_kes = 5.00,
      price_per_km_kes = 9.00,
      price_per_min_kes = 2.00,
      min_fare_kes = 25.00,
      updated_at = NOW()
    WHERE slug = 'comfort'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 22.00,
      booking_fee_kes = 6.00,
      price_per_km_kes = 12.00,
      price_per_min_kes = 3.00,
      min_fare_kes = 30.00,
      updated_at = NOW()
    WHERE slug = 'xl'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 15.00,
      booking_fee_kes = 4.00,
      price_per_km_kes = 7.00,
      price_per_min_kes = 2.00,
      min_fare_kes = 22.00,
      updated_at = NOW()
    WHERE slug = 'women_only'
    """)

    execute("""
    UPDATE vehicle_categories
    SET
      base_fee_kes = 14.00,
      booking_fee_kes = 4.00,
      price_per_km_kes = 7.00,
      price_per_min_kes = 2.00,
      min_fare_kes = 20.00,
      updated_at = NOW()
    WHERE slug = 'green'
    """)
  end
end
