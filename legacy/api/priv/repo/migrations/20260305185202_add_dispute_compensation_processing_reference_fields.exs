defmodule Liddr.Repo.Migrations.AddDisputeCompensationProcessingReferenceFields do
  use Ecto.Migration

  def change do
    alter table(:dispute_compensations) do
      add :processing_reference, :string
      add :processing_channel, :string
    end

    create index(:dispute_compensations, [:processing_channel, :inserted_at])

    create constraint(
             :dispute_compensations,
             :dispute_compensations_processing_channel_valid,
             check:
               "processing_channel IS NULL OR processing_channel IN ('manual_ops', 'mpesa_reversal', 'wallet_credit', 'bank_transfer')"
           )

    create constraint(
             :dispute_compensations,
             :dispute_compensations_paid_requires_processing_reference,
             check:
               "(status != 'paid') OR (processing_reference IS NOT NULL AND btrim(processing_reference) != '')"
           )
  end
end
