defmodule Liddr.Repo.Migrations.AddRideExecutionStateAndCompletionFields do
  use Ecto.Migration

  def up do
    drop constraint(:rides, :rides_status_valid)
    drop constraint(:drivers, :drivers_dispatch_status_valid)

    alter table(:rides) do
      add :driver_arriving_at, :utc_datetime_usec
      add :arrived_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :payment_mode, :string
      add :final_fare_kes, :decimal, precision: 10, scale: 2
      add :final_pricing_payload, :map, null: false, default: %{}
    end

    create constraint(:rides, :rides_status_valid,
             check:
               "status IN ('requested', 'offering', 'accepted', 'driver_arriving', 'arrived', 'in_progress', 'cancelled', 'completed')"
           )

    create constraint(:rides, :rides_payment_mode_valid,
             check:
               "payment_mode IS NULL OR payment_mode IN ('cash_direct', 'mpesa_direct', 'in_app_mpesa')"
           )

    create constraint(:rides, :rides_completion_money_non_negative,
             check: "final_fare_kes IS NULL OR final_fare_kes >= 0"
           )

    create constraint(:drivers, :drivers_dispatch_status_valid,
             check: "dispatch_status IN ('idle', 'heading_to_pickup', 'at_pickup', 'on_trip')"
           )
  end

  def down do
    drop constraint(:rides, :rides_completion_money_non_negative)
    drop constraint(:rides, :rides_payment_mode_valid)
    drop constraint(:rides, :rides_status_valid)
    drop constraint(:drivers, :drivers_dispatch_status_valid)

    alter table(:rides) do
      remove :final_pricing_payload
      remove :final_fare_kes
      remove :payment_mode
      remove :started_at
      remove :arrived_at
      remove :driver_arriving_at
    end

    create constraint(:rides, :rides_status_valid,
             check: "status IN ('requested', 'offering', 'accepted', 'cancelled', 'completed')"
           )

    create constraint(:drivers, :drivers_dispatch_status_valid,
             check: "dispatch_status IN ('idle', 'heading_to_pickup', 'on_trip')"
           )
  end
end
