defmodule Liddr.Repo.Migrations.TuneDiscountPercentTo15ForCompetitivePricing do
  use Ecto.Migration

  def up do
    alter table(:vehicle_categories) do
      modify :discount_percent, :decimal, precision: 5, scale: 2, null: false, default: 15
    end

    execute("""
    UPDATE vehicle_categories
    SET discount_percent = 15.00, updated_at = NOW()
    WHERE is_active = TRUE
    """)
  end

  def down do
    alter table(:vehicle_categories) do
      modify :discount_percent, :decimal, precision: 5, scale: 2, null: false, default: 0
    end

    execute("""
    UPDATE vehicle_categories
    SET discount_percent = 10.00, updated_at = NOW()
    WHERE is_active = TRUE
    """)
  end
end
