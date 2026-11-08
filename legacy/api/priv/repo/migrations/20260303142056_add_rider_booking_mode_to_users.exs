defmodule Liddr.Repo.Migrations.AddRiderBookingModeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :ride_booking_mode, :string, null: false, default: "normal"
      add :ride_booking_mode_until, :utc_datetime_usec
    end

    create index(:users, [:ride_booking_mode, :ride_booking_mode_until])

    create constraint(:users, :users_ride_booking_mode_valid,
             check: "ride_booking_mode IN ('normal', 'prepay_only')"
           )

    create constraint(:users, :users_ride_booking_mode_until_required,
             check: "ride_booking_mode <> 'prepay_only' OR ride_booking_mode_until IS NOT NULL"
           )
  end
end
