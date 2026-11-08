defmodule Liddr.Repo.Migrations.AddRideDestinationChangeRequestsAndProductType do
  use Ecto.Migration

  def change do
    alter table(:rides) do
      add :product_type, :string, null: false, default: "solo"
    end

    create constraint(:rides, :rides_product_type_valid,
             check: "product_type IN ('solo', 'shared')"
           )

    create index(:rides, [:product_type, :status, :inserted_at])

    create table(:ride_destination_changes) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :requested_by_user_id, references(:users, on_delete: :delete_all), null: false
      add :driver_id, references(:users, on_delete: :delete_all), null: false
      add :old_dropoff_lat, :decimal, precision: 10, scale: 7, null: false
      add :old_dropoff_lng, :decimal, precision: 10, scale: 7, null: false
      add :new_dropoff_lat, :decimal, precision: 10, scale: 7, null: false
      add :new_dropoff_lng, :decimal, precision: 10, scale: 7, null: false
      add :old_fare_kes, :decimal, precision: 10, scale: 2, null: false
      add :new_fare_kes, :decimal, precision: 10, scale: 2, null: false
      add :fare_delta_kes, :decimal, precision: 10, scale: 2, null: false
      add :status, :string, null: false, default: "requested"
      add :reason_code, :string, null: false
      add :notes, :text
      add :requested_at, :utc_datetime_usec, null: false
      add :responded_at, :utc_datetime_usec
      add :pricing_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ride_destination_changes, [:ride_id, :inserted_at])
    create index(:ride_destination_changes, [:ride_id, :status, :inserted_at])
    create index(:ride_destination_changes, [:driver_id, :status, :inserted_at])

    create unique_index(:ride_destination_changes, [:ride_id],
             where: "status = 'requested'",
             name: :ride_destination_changes_one_open_per_ride
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_status_valid,
             check: "status IN ('requested', 'accepted', 'rejected', 'expired')"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_reason_non_empty,
             check: "char_length(trim(reason_code)) > 0"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_money_non_negative,
             check: "old_fare_kes >= 0 AND new_fare_kes >= 0"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_responded_when_closed,
             check:
               "(status = 'requested' AND responded_at IS NULL) OR (status <> 'requested' AND responded_at IS NOT NULL)"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_old_dropoff_lat_range,
             check: "old_dropoff_lat >= -90 AND old_dropoff_lat <= 90"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_old_dropoff_lng_range,
             check: "old_dropoff_lng >= -180 AND old_dropoff_lng <= 180"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_new_dropoff_lat_range,
             check: "new_dropoff_lat >= -90 AND new_dropoff_lat <= 90"
           )

    create constraint(:ride_destination_changes, :ride_destination_changes_new_dropoff_lng_range,
             check: "new_dropoff_lng >= -180 AND new_dropoff_lng <= 180"
           )
  end
end
