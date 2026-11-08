defmodule Liddr.Repo.Migrations.CreateSubscriptionBillingTables do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :vehicle_category_id, references(:vehicle_categories, on_delete: :restrict), null: false
      add :week_start, :date, null: false
      add :week_end, :date, null: false
      add :amount_kes, :decimal, precision: 10, scale: 2, null: false
      add :status, :string, null: false, default: "pending"
      add :activated_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subscriptions, [:driver_id, :status])
    create index(:subscriptions, [:week_end, :status])
    create unique_index(:subscriptions, [:driver_id, :week_start, :week_end])

    create constraint(:subscriptions, :subscriptions_status_valid,
             check: "status IN ('pending', 'active', 'grace', 'expired', 'cancelled')"
           )

    create constraint(:subscriptions, :subscriptions_week_range_valid,
             check: "week_end >= week_start"
           )

    create constraint(:subscriptions, :subscriptions_amount_non_negative,
             check: "amount_kes >= 0"
           )

    create table(:subscription_payments) do
      add :subscription_id, references(:subscriptions, on_delete: :restrict), null: false
      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :provider, :string, null: false, default: "mpesa"
      add :payment_channel, :string, null: false, default: "stk_push"
      add :status, :string, null: false, default: "initiated"
      add :amount_kes, :decimal, precision: 10, scale: 2, null: false
      add :currency, :string, null: false, default: "KES"
      add :phone_e164, :string
      add :merchant_request_id, :string
      add :checkout_request_id, :string
      add :mpesa_receipt_number, :string
      add :transaction_id, :string
      add :result_code, :integer
      add :result_desc, :text
      add :conversation_id, :string
      add :originator_conversation_id, :string
      add :requested_at, :utc_datetime_usec, null: false
      add :callback_received_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :request_payload, :map, null: false, default: %{}
      add :callback_payload, :map
      add :status_query_payload, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:subscription_payments, [:subscription_id])
    create index(:subscription_payments, [:driver_id, :inserted_at])
    create index(:subscription_payments, [:status, :inserted_at])

    create unique_index(:subscription_payments, [:checkout_request_id],
             where: "checkout_request_id IS NOT NULL"
           )

    create unique_index(:subscription_payments, [:mpesa_receipt_number],
             where: "mpesa_receipt_number IS NOT NULL"
           )

    create unique_index(:subscription_payments, [:transaction_id],
             where: "transaction_id IS NOT NULL"
           )

    create constraint(:subscription_payments, :subscription_payments_provider_valid,
             check: "provider IN ('mpesa')"
           )

    create constraint(:subscription_payments, :subscription_payments_channel_valid,
             check: "payment_channel IN ('stk_push', 'c2b')"
           )

    create constraint(:subscription_payments, :subscription_payments_status_valid,
             check:
               "status IN ('initiated', 'pending_callback', 'success', 'failed', 'cancelled', 'timeout')"
           )

    create constraint(:subscription_payments, :subscription_payments_currency_valid,
             check: "currency = 'KES'"
           )

    create constraint(:subscription_payments, :subscription_payments_amount_non_negative,
             check: "amount_kes >= 0"
           )

    create table(:webhook_events) do
      add :provider, :string, null: false
      add :event_type, :string, null: false
      add :external_ref, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :processed_at, :utc_datetime_usec
      add :processing_error, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:webhook_events, [:provider, :event_type, :external_ref])
    create index(:webhook_events, [:processed_at])

    create constraint(:webhook_events, :webhook_events_provider_valid,
             check: "provider IN ('mpesa')"
           )

    create constraint(:webhook_events, :webhook_events_type_valid,
             check: "event_type IN ('stk_callback', 'c2b_callback', 'tx_status_callback')"
           )
  end
end
