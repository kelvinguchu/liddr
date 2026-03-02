defmodule Liddr.Repo.Migrations.RemoveBoltCategoryFromDefaultCatalog do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM vehicle_categories vc
    WHERE vc.slug = 'bolt'
      AND NOT EXISTS (
        SELECT 1
        FROM drivers d
        WHERE d.vehicle_category_id = vc.id
      )
    """)

    execute("""
    UPDATE vehicle_categories
    SET is_active = false, updated_at = NOW()
    WHERE slug = 'bolt'
    """)
  end

  def down do
    execute("""
    INSERT INTO vehicle_categories (
      slug,
      label,
      capacity,
      base_fee_kes,
      price_per_km_kes,
      weekly_sub_kes,
      is_active,
      inserted_at,
      updated_at,
      min_fare_kes,
      price_per_min_kes,
      booking_fee_kes
    )
    VALUES (
      'bolt',
      'Bolt',
      4,
      70.00,
      35.00,
      2100,
      false,
      NOW(),
      NOW(),
      210.00,
      7.00,
      30.00
    )
    ON CONFLICT (slug) DO NOTHING
    """)
  end
end
