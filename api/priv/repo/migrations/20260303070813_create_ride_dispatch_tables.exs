defmodule Liddr.Repo.Migrations.CreateRideDispatchTables do
  use Ecto.Migration

  def change do
    create table(:rides) do
      add :rider_id, references(:users, on_delete: :restrict), null: false
      add :driver_id, references(:drivers, column: :user_id, on_delete: :nilify_all)
      add :vehicle_category_id, references(:vehicle_categories, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "requested"
      add :pickup_lat, :decimal, precision: 10, scale: 7, null: false
      add :pickup_lng, :decimal, precision: 10, scale: 7, null: false
      add :dropoff_lat, :decimal, precision: 10, scale: 7, null: false
      add :dropoff_lng, :decimal, precision: 10, scale: 7, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :notes, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rides, [:rider_id, :inserted_at])
    create index(:rides, [:driver_id, :inserted_at])
    create index(:rides, [:status, :inserted_at])
    create index(:rides, [:vehicle_category_id, :status, :inserted_at])

    create constraint(:rides, :rides_status_valid,
             check: "status IN ('requested', 'offering', 'accepted', 'cancelled', 'completed')"
           )

    create constraint(:rides, :rides_pickup_lat_range,
             check: "pickup_lat >= -90 AND pickup_lat <= 90"
           )

    create constraint(:rides, :rides_dropoff_lat_range,
             check: "dropoff_lat >= -90 AND dropoff_lat <= 90"
           )

    create constraint(:rides, :rides_pickup_lng_range,
             check: "pickup_lng >= -180 AND pickup_lng <= 180"
           )

    create constraint(:rides, :rides_dropoff_lng_range,
             check: "dropoff_lng >= -180 AND dropoff_lng <= 180"
           )

    create constraint(:rides, :rides_accepted_driver_presence,
             check: "status <> 'accepted' OR driver_id IS NOT NULL"
           )

    create table(:ride_offers) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "offered"
      add :offered_at, :utc_datetime_usec, null: false
      add :responded_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ride_offers, [:ride_id, :status, :inserted_at])
    create index(:ride_offers, [:driver_id, :status, :expires_at])
    create index(:ride_offers, [:status, :expires_at])
    create unique_index(:ride_offers, [:ride_id, :driver_id])

    create constraint(:ride_offers, :ride_offers_status_valid,
             check: "status IN ('offered', 'accepted', 'rejected', 'expired', 'withdrawn')"
           )

    create constraint(:ride_offers, :ride_offers_temporal_window_valid,
             check: "expires_at > offered_at"
           )
  end
end
