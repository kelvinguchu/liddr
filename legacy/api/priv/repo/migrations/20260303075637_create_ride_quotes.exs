defmodule Liddr.Repo.Migrations.CreateRideQuotes do
  use Ecto.Migration

  def change do
    create table(:ride_quotes) do
      add :rider_id, references(:users, on_delete: :delete_all), null: false
      add :vehicle_category_id, references(:vehicle_categories, on_delete: :restrict), null: false
      add :pickup_lat, :decimal, precision: 10, scale: 7, null: false
      add :pickup_lng, :decimal, precision: 10, scale: 7, null: false
      add :dropoff_lat, :decimal, precision: 10, scale: 7, null: false
      add :dropoff_lng, :decimal, precision: 10, scale: 7, null: false
      add :distance_m, :integer, null: false
      add :duration_s, :integer, null: false
      add :static_duration_s, :integer
      add :base_amount_kes, :decimal, precision: 10, scale: 2, null: false
      add :distance_amount_kes, :decimal, precision: 10, scale: 2, null: false
      add :time_amount_kes, :decimal, precision: 10, scale: 2, null: false
      add :booking_fee_kes, :decimal, precision: 10, scale: 2, null: false
      add :min_fare_kes, :decimal, precision: 10, scale: 2, null: false
      add :surge_multiplier, :decimal, precision: 5, scale: 2, null: false, default: 1
      add :subtotal_kes, :decimal, precision: 10, scale: 2, null: false
      add :final_fare_kes, :decimal, precision: 10, scale: 2, null: false
      add :currency, :string, null: false, default: "KES"
      add :provider, :string, null: false, default: "google_routes"
      add :provider_payload, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ride_quotes, [:rider_id, :inserted_at])
    create index(:ride_quotes, [:vehicle_category_id, :inserted_at])
    create index(:ride_quotes, [:expires_at])

    create constraint(:ride_quotes, :ride_quotes_pickup_lat_range,
             check: "pickup_lat >= -90 AND pickup_lat <= 90"
           )

    create constraint(:ride_quotes, :ride_quotes_dropoff_lat_range,
             check: "dropoff_lat >= -90 AND dropoff_lat <= 90"
           )

    create constraint(:ride_quotes, :ride_quotes_pickup_lng_range,
             check: "pickup_lng >= -180 AND pickup_lng <= 180"
           )

    create constraint(:ride_quotes, :ride_quotes_dropoff_lng_range,
             check: "dropoff_lng >= -180 AND dropoff_lng <= 180"
           )

    create constraint(:ride_quotes, :ride_quotes_distance_non_negative, check: "distance_m >= 0")

    create constraint(:ride_quotes, :ride_quotes_duration_non_negative,
             check: "duration_s >= 0 AND (static_duration_s IS NULL OR static_duration_s >= 0)"
           )

    create constraint(:ride_quotes, :ride_quotes_money_non_negative,
             check:
               "base_amount_kes >= 0 AND distance_amount_kes >= 0 AND time_amount_kes >= 0 AND booking_fee_kes >= 0 AND min_fare_kes >= 0 AND subtotal_kes >= 0 AND final_fare_kes >= 0"
           )

    create constraint(:ride_quotes, :ride_quotes_surge_range,
             check: "surge_multiplier >= 1 AND surge_multiplier <= 5"
           )

    create constraint(:ride_quotes, :ride_quotes_currency_kes, check: "currency = 'KES'")

    alter table(:rides) do
      add :quote_id, references(:ride_quotes, on_delete: :nilify_all)
    end

    create index(:rides, [:quote_id])
  end
end
