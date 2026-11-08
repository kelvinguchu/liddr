defmodule Liddr.Repo.Migrations.CreateDisputeCompensations do
  use Ecto.Migration

  def change do
    create table(:dispute_compensations) do
      add :report_id, references(:reports, on_delete: :delete_all), null: false
      add :ride_id, references(:rides, on_delete: :nilify_all), null: false
      add :beneficiary_user_id, references(:users, on_delete: :restrict), null: false
      add :counterparty_user_id, references(:users, on_delete: :nilify_all)
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :compensation_type, :string, null: false
      add :status, :string, null: false, default: "approved"
      add :amount_kes, :decimal, precision: 12, scale: 2, null: false
      add :currency, :string, null: false, default: "KES"
      add :reason_code, :string
      add :reason_text, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:dispute_compensations, [:report_id],
             name: :dispute_compensations_unique_report_idx
           )

    create index(:dispute_compensations, [:beneficiary_user_id, :inserted_at])
    create index(:dispute_compensations, [:ride_id, :inserted_at])
    create index(:dispute_compensations, [:compensation_type, :status, :inserted_at])

    create constraint(:dispute_compensations, :dispute_compensations_type_valid,
             check: "compensation_type IN ('refund_full', 'refund_partial', 'credit_note')"
           )

    create constraint(:dispute_compensations, :dispute_compensations_status_valid,
             check: "status IN ('approved', 'paid', 'cancelled')"
           )

    create constraint(:dispute_compensations, :dispute_compensations_amount_positive,
             check: "amount_kes > 0"
           )

    create constraint(:dispute_compensations, :dispute_compensations_currency_kes,
             check: "currency = 'KES'"
           )
  end
end
