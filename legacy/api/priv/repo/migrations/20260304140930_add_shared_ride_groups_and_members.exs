defmodule Liddr.Repo.Migrations.AddSharedRideGroupsAndMembers do
  use Ecto.Migration

  def change do
    create table(:shared_ride_groups) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :max_members, :integer, null: false, default: 2
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:shared_ride_groups, [:ride_id])

    create constraint(:shared_ride_groups, :shared_ride_groups_max_members_valid,
             check: "max_members >= 2 AND max_members <= 6"
           )

    create table(:shared_ride_members) do
      add :group_id, references(:shared_ride_groups, on_delete: :delete_all), null: false
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :rider_user_id, references(:users, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "requested"
      add :requested_at, :utc_datetime_usec, null: false
      add :picked_up_at, :utc_datetime_usec
      add :dropped_off_at, :utc_datetime_usec
      add :cancelled_at, :utc_datetime_usec
      add :no_show_marked_at, :utc_datetime_usec
      add :cancellation_reason_code, :string
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)
      add :fare_kes, :decimal, precision: 10, scale: 2
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:shared_ride_members, [:group_id, :status, :inserted_at])
    create index(:shared_ride_members, [:ride_id, :status, :inserted_at])
    create index(:shared_ride_members, [:rider_user_id, :status, :inserted_at])
    create unique_index(:shared_ride_members, [:group_id, :rider_user_id])

    create constraint(:shared_ride_members, :shared_ride_members_status_valid,
             check:
               "status IN ('requested', 'assigned', 'pickup_pending', 'picked_up', 'dropoff_pending', 'dropped_off', 'cancelled', 'no_show')"
           )

    create constraint(:shared_ride_members, :shared_ride_members_fare_non_negative,
             check: "fare_kes IS NULL OR fare_kes >= 0"
           )

    create constraint(:shared_ride_members, :shared_ride_members_cancelled_when_cancelled,
             check:
               "(status <> 'cancelled') OR (cancelled_at IS NOT NULL AND cancellation_reason_code IS NOT NULL)"
           )

    create constraint(:shared_ride_members, :shared_ride_members_no_show_when_no_show,
             check: "(status <> 'no_show') OR no_show_marked_at IS NOT NULL"
           )

    create table(:shared_ride_stops) do
      add :group_id, references(:shared_ride_groups, on_delete: :delete_all), null: false
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :member_id, references(:shared_ride_members, on_delete: :nilify_all)
      add :stop_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :sequence, :integer, null: false
      add :lat, :decimal, precision: 10, scale: 7, null: false
      add :lng, :decimal, precision: 10, scale: 7, null: false
      add :eta_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:shared_ride_stops, [:group_id, :status, :sequence])
    create index(:shared_ride_stops, [:ride_id, :sequence])
    create unique_index(:shared_ride_stops, [:group_id, :sequence])

    create constraint(:shared_ride_stops, :shared_ride_stops_stop_type_valid,
             check: "stop_type IN ('pickup', 'dropoff')"
           )

    create constraint(:shared_ride_stops, :shared_ride_stops_status_valid,
             check: "status IN ('pending', 'completed', 'skipped', 'cancelled')"
           )

    create constraint(:shared_ride_stops, :shared_ride_stops_lat_range,
             check: "lat >= -90 AND lat <= 90"
           )

    create constraint(:shared_ride_stops, :shared_ride_stops_lng_range,
             check: "lng >= -180 AND lng <= 180"
           )
  end
end
