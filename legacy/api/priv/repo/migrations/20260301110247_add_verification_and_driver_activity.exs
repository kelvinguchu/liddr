defmodule Liddr.Repo.Migrations.AddVerificationAndDriverActivity do
  use Ecto.Migration

  def change do
    alter table(:drivers) do
      add :account_status, :string, null: false, default: "pending"
      add :verification_status, :string, null: false, default: "unverified"
      add :last_seen_at, :utc_datetime_usec
      add :last_online_at, :utc_datetime_usec
      add :activated_at, :utc_datetime_usec
      add :suspended_at, :utc_datetime_usec
    end

    create index(:drivers, [:account_status, :verification_status])
    create index(:drivers, [:last_seen_at])

    create constraint(:drivers, :drivers_account_status_valid,
             check: "account_status IN ('pending', 'active', 'suspended', 'deactivated')"
           )

    create constraint(:drivers, :drivers_verification_status_valid,
             check:
               "verification_status IN ('unverified', 'pending', 'under_review', 'approved', 'rejected', 'suspended')"
           )

    create table(:verification_requirements) do
      add :document_type, :string, null: false
      add :label, :string, null: false
      add :required, :boolean, null: false, default: true
      add :requires_expiry, :boolean, null: false, default: false
      add :is_active, :boolean, null: false, default: true
      add :display_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:verification_requirements, [:document_type])
    create index(:verification_requirements, [:is_active, :display_order])

    create constraint(
             :verification_requirements,
             :verification_requirements_display_order_non_negative,
             check: "display_order >= 0"
           )

    create table(:verification_applications) do
      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "pending"
      add :provider, :string, null: false, default: "internal"
      add :provider_reference, :string
      add :submitted_at, :utc_datetime_usec
      add :decided_at, :utc_datetime_usec
      add :decision_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:verification_applications, [:driver_id, :status])
    create index(:verification_applications, [:inserted_at])

    create unique_index(:verification_applications, [:driver_id],
             where: "status IN ('pending', 'under_review', 'resubmission_required')"
           )

    create constraint(:verification_applications, :verification_applications_status_valid,
             check:
               "status IN ('pending', 'under_review', 'approved', 'rejected', 'resubmission_required', 'suspended')"
           )

    create constraint(:verification_applications, :verification_applications_provider_valid,
             check: "provider IN ('internal', 'sumsub', 'idenfy')"
           )

    create table(:verification_documents) do
      add :application_id, references(:verification_applications, on_delete: :delete_all),
        null: false

      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :document_type, :string, null: false
      add :version, :integer, null: false, default: 1
      add :capture_source, :string, null: false, default: "camera_live"
      add :status, :string, null: false, default: "uploaded"
      add :storage_key, :string, null: false
      add :checksum_sha256, :string
      add :file_mime, :string
      add :file_size_bytes, :bigint
      add :expires_on, :date
      add :reviewed_at, :utc_datetime_usec
      add :rejection_reason, :text
      add :ocr_payload, :map, null: false, default: %{}
      add :extracted_data, :map, null: false, default: %{}
      add :capture_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:verification_documents, [:driver_id, :document_type, :status])
    create index(:verification_documents, [:expires_on])
    create unique_index(:verification_documents, [:application_id, :document_type, :version])

    create constraint(:verification_documents, :verification_documents_version_valid,
             check: "version >= 1"
           )

    create constraint(:verification_documents, :verification_documents_capture_source_valid,
             check: "capture_source IN ('camera_live', 'ops_upload')"
           )

    create constraint(:verification_documents, :verification_documents_status_valid,
             check:
               "status IN ('uploaded', 'pending_review', 'validated', 'rejected', 'expired', 'resubmission_required')"
           )

    create constraint(:verification_documents, :verification_documents_size_non_negative,
             check: "file_size_bytes IS NULL OR file_size_bytes >= 0"
           )

    create table(:verification_checks) do
      add :application_id, references(:verification_applications, on_delete: :delete_all),
        null: false

      add :document_id, references(:verification_documents, on_delete: :nilify_all)
      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :check_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :score, :decimal, precision: 5, scale: 2
      add :checked_at, :utc_datetime_usec
      add :checked_by_user_id, references(:users, on_delete: :nilify_all)
      add :notes, :text
      add :response_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:verification_checks, [:application_id, :check_type, :status])
    create index(:verification_checks, [:driver_id, :inserted_at])

    create constraint(:verification_checks, :verification_checks_type_valid,
             check:
               "check_type IN ('ocr', 'face_match', 'metadata', 'manual_ntsa', 'manual_police', 'manual_vehicle')"
           )

    create constraint(:verification_checks, :verification_checks_status_valid,
             check: "status IN ('pending', 'passed', 'failed', 'needs_review')"
           )

    create constraint(:verification_checks, :verification_checks_score_range,
             check: "score IS NULL OR (score >= 0 AND score <= 100)"
           )

    create table(:verification_reviews) do
      add :application_id, references(:verification_applications, on_delete: :delete_all),
        null: false

      add :driver_id, references(:drivers, column: :user_id, on_delete: :restrict), null: false
      add :reviewer_user_id, references(:users, on_delete: :restrict), null: false
      add :decision, :string, null: false
      add :reason, :text
      add :decided_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:verification_reviews, [:application_id, :decided_at])
    create index(:verification_reviews, [:driver_id, :decided_at])

    create constraint(:verification_reviews, :verification_reviews_decision_valid,
             check: "decision IN ('approve', 'reject', 'request_resubmission', 'suspend')"
           )

    create table(:driver_activity_events) do
      add :driver_id, references(:drivers, column: :user_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :previous_value, :string
      add :new_value, :string
      add :reason_code, :string
      add :reason_text, :text
      add :actor_type, :string, null: false
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:driver_activity_events, [:driver_id, :inserted_at])
    create index(:driver_activity_events, [:event_type, :inserted_at])

    create constraint(:driver_activity_events, :driver_activity_events_event_type_valid,
             check:
               "event_type IN ('status_changed', 'went_online', 'went_offline', 'subscription_updated', 'verification_updated')"
           )

    create constraint(:driver_activity_events, :driver_activity_events_actor_type_valid,
             check: "actor_type IN ('system', 'driver', 'ops')"
           )
  end
end
