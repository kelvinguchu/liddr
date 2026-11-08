defmodule Liddr.Repo.Migrations.CreateCoreDomainTables do
  use Ecto.Migration

  def change do
    create table(:vehicle_categories) do
      add :slug, :string, null: false
      add :label, :string, null: false
      add :capacity, :integer, null: false
      add :base_fee_kes, :decimal, precision: 10, scale: 2, null: false
      add :price_per_km_kes, :decimal, precision: 10, scale: 2, null: false
      add :weekly_sub_kes, :integer, null: false
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vehicle_categories, [:slug])

    create constraint(:vehicle_categories, :vehicle_categories_capacity_non_negative,
             check: "capacity >= 0"
           )

    create constraint(:vehicle_categories, :vehicle_categories_base_fee_non_negative,
             check: "base_fee_kes >= 0"
           )

    create constraint(:vehicle_categories, :vehicle_categories_price_per_km_non_negative,
             check: "price_per_km_kes >= 0"
           )

    create constraint(:vehicle_categories, :vehicle_categories_weekly_sub_non_negative,
             check: "weekly_sub_kes >= 0"
           )

    create table(:users) do
      add :phone, :string
      add :google_id, :string
      add :role, :string, null: false
      add :gender, :string
      add :rating_score, :decimal, precision: 3, scale: 2
      add :rating_count, :integer, null: false, default: 0
      add :rating_weighted_sum, :decimal, precision: 12, scale: 4, null: false, default: 0
      add :phone_verified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:phone], where: "phone IS NOT NULL")
    create unique_index(:users, [:google_id], where: "google_id IS NOT NULL")

    create constraint(:users, :users_role_valid, check: "role IN ('driver', 'passenger')")

    create constraint(:users, :users_gender_valid,
             check: "gender IS NULL OR gender IN ('female', 'male', 'other', 'unknown')"
           )

    create constraint(:users, :users_rating_score_range,
             check: "rating_score IS NULL OR (rating_score >= 1 AND rating_score <= 5)"
           )

    create constraint(:users, :users_rating_count_non_negative, check: "rating_count >= 0")

    create table(:drivers, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true
      add :license_no, :string
      add :plate_no, :string
      add :vehicle_category_id, references(:vehicle_categories, on_delete: :restrict), null: false
      add :vehicle_year, :integer
      add :subscription_status, :string, null: false, default: "inactive"
      add :is_available, :boolean, null: false, default: false
      add :gender_verified, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:drivers, [:vehicle_category_id])
    create unique_index(:drivers, [:plate_no], where: "plate_no IS NOT NULL")

    create constraint(:drivers, :drivers_subscription_status_valid,
             check: "subscription_status IN ('inactive', 'active', 'grace', 'suspended')"
           )

    create constraint(:drivers, :drivers_vehicle_year_range,
             check: "vehicle_year IS NULL OR (vehicle_year >= 1980 AND vehicle_year <= 2100)"
           )
  end
end
