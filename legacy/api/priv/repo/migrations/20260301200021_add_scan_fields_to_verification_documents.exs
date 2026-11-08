defmodule Liddr.Repo.Migrations.AddScanFieldsToVerificationDocuments do
  use Ecto.Migration

  def up do
    alter table(:verification_documents) do
      add :scan_status, :string, null: false, default: "pending"
      add :scanned_at, :utc_datetime_usec
      add :scan_engine, :string
      add :scan_signature, :string
      add :scan_error, :string
    end

    create index(:verification_documents, [:scan_status])

    execute("""
    UPDATE verification_documents
    SET scan_status = 'clean',
        scanned_at = NOW(),
        scan_engine = 'legacy'
    WHERE scan_status = 'pending'
      AND status IN ('uploaded', 'pending_review', 'validated', 'resubmission_required');
    """)
  end

  def down do
    drop index(:verification_documents, [:scan_status])

    alter table(:verification_documents) do
      remove :scan_error
      remove :scan_signature
      remove :scan_engine
      remove :scanned_at
      remove :scan_status
    end
  end
end
