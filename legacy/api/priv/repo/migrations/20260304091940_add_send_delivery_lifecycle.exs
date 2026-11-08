defmodule Liddr.Repo.Migrations.AddSendDeliveryLifecycle do
  use Ecto.Migration

  def change do
    create table(:send_deliveries) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false

      add :sender_name, :string, null: false
      add :sender_phone, :string
      add :recipient_name, :string, null: false
      add :recipient_phone, :string, null: false
      add :item_description, :string, null: false
      add :item_size, :string, null: false
      add :payer, :string, null: false
      add :payment_timing, :string, null: false
      add :item_value_kes, :decimal, precision: 12, scale: 2
      add :special_instructions, :text
      add :liability_acknowledged, :boolean, null: false, default: false
      add :prohibited_item_warnings, :map, null: false, default: %{}

      add :pickup_proof_key, :string
      add :pickup_proof_captured_at, :utc_datetime_usec
      add :dropoff_proof_key, :string
      add :dropoff_proof_captured_at, :utc_datetime_usec

      add :recipient_confirmation_token_hash, :string
      add :recipient_confirmation_expires_at, :utc_datetime_usec
      add :recipient_confirmed_at, :utc_datetime_usec
      add :recipient_confirmation_status, :string, null: false, default: "pending"
      add :delivery_status, :string, null: false, default: "pending_pickup"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:send_deliveries, [:ride_id])
    create index(:send_deliveries, [:delivery_status, :updated_at])
    create index(:send_deliveries, [:recipient_confirmation_status, :updated_at])
    create unique_index(:send_deliveries, [:recipient_confirmation_token_hash])

    create constraint(
             :send_deliveries,
             :send_deliveries_item_size_valid,
             check: "item_size IN ('small', 'medium', 'large')"
           )

    create constraint(
             :send_deliveries,
             :send_deliveries_payer_valid,
             check: "payer IN ('sender', 'recipient')"
           )

    create constraint(
             :send_deliveries,
             :send_deliveries_payment_timing_valid,
             check: "payment_timing IN ('before', 'after')"
           )

    create constraint(
             :send_deliveries,
             :send_deliveries_recipient_confirmation_status_valid,
             check: "recipient_confirmation_status IN ('pending', 'confirmed', 'expired')"
           )

    create constraint(
             :send_deliveries,
             :send_deliveries_delivery_status_valid,
             check:
               "delivery_status IN ('pending_pickup', 'in_transit', 'delivered_pending_confirmation', 'delivered_confirmed', 'completed')"
           )

    create constraint(
             :send_deliveries,
             :send_deliveries_item_value_non_negative,
             check: "item_value_kes IS NULL OR item_value_kes >= 0"
           )
  end
end
