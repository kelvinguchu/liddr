defmodule Liddr.Repo.Migrations.AddDriverDispatchStateAndLocations do
  use Ecto.Migration

  def change do
    alter table(:drivers) do
      add :current_ride_id, references(:rides, on_delete: :nilify_all)
      add :dispatch_status, :string, null: false, default: "idle"
    end

    create index(:drivers, [:current_ride_id])
    create index(:drivers, [:dispatch_status, :vehicle_category_id, :is_available])

    create constraint(:drivers, :drivers_dispatch_status_valid,
             check: "dispatch_status IN ('idle', 'heading_to_pickup', 'on_trip')"
           )

    create table(:driver_locations, primary_key: false) do
      add :driver_id, references(:drivers, column: :user_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :lat, :decimal, precision: 10, scale: 7, null: false
      add :lng, :decimal, precision: 10, scale: 7, null: false
      add :captured_at, :utc_datetime_usec, null: false
      add :s2_cell_token, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:driver_locations, [:captured_at])
    create index(:driver_locations, [:lat, :lng])
    create index(:driver_locations, [:s2_cell_token])

    create constraint(:driver_locations, :driver_locations_lat_range,
             check: "lat >= -90 AND lat <= 90"
           )

    create constraint(:driver_locations, :driver_locations_lng_range,
             check: "lng >= -180 AND lng <= 180"
           )
  end
end
