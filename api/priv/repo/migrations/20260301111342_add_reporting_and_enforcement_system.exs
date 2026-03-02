defmodule Liddr.Repo.Migrations.AddReportingAndEnforcementSystem do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :account_status, :string, null: false, default: "active"
      add :account_status_reason_code, :string
      add :account_restricted_at, :utc_datetime_usec
      add :account_restricted_until, :utc_datetime_usec
      add :account_banned_at, :utc_datetime_usec
    end

    create index(:users, [:account_status, :account_restricted_until])

    create constraint(:users, :users_account_status_valid,
             check:
               "account_status IN ('active', 'restricted', 'suspended', 'banned', 'deactivated')"
           )

    create table(:report_categories) do
      add :slug, :string, null: false
      add :label, :string, null: false
      add :description, :text
      add :applies_to, :string, null: false, default: "both"
      add :severity_level_default, :integer, null: false
      add :recommended_action, :string, null: false, default: "review"
      add :requires_immediate_attention, :boolean, null: false, default: false
      add :is_active, :boolean, null: false, default: true
      add :display_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:report_categories, [:slug])
    create index(:report_categories, [:is_active, :display_order])

    create constraint(:report_categories, :report_categories_applies_to_valid,
             check: "applies_to IN ('driver', 'passenger', 'both')"
           )

    create constraint(:report_categories, :report_categories_severity_range,
             check: "severity_level_default >= 1 AND severity_level_default <= 5"
           )

    create constraint(:report_categories, :report_categories_recommended_action_valid,
             check:
               "recommended_action IN ('review', 'warn', 'temporary_suspension', 'permanent_ban')"
           )

    create constraint(:report_categories, :report_categories_display_order_non_negative,
             check: "display_order >= 0"
           )

    create table(:reports) do
      add :reporter_user_id, references(:users, on_delete: :restrict), null: false
      add :reported_user_id, references(:users, on_delete: :restrict), null: false
      add :reported_driver_id, references(:drivers, column: :user_id, on_delete: :nilify_all)
      add :category_id, references(:report_categories, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "submitted"
      add :severity_level, :integer, null: false
      add :source, :string, null: false, default: "in_app"
      add :incident_type, :string, null: false, default: "conduct"
      add :context_type, :string
      add :context_reference, :string
      add :incident_at, :utc_datetime_usec
      add :description, :text, null: false
      add :reporter_contact_opt_in, :boolean, null: false, default: false
      add :is_anonymous_to_reported, :boolean, null: false, default: true
      add :assigned_reviewer_user_id, references(:users, on_delete: :nilify_all)
      add :triaged_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :resolution_outcome, :string
      add :resolution_summary, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reports, [:reporter_user_id, :inserted_at])
    create index(:reports, [:reported_user_id, :status, :inserted_at])
    create index(:reports, [:category_id, :status, :inserted_at])
    create index(:reports, [:assigned_reviewer_user_id, :status])
    create index(:reports, [:status, :severity_level, :inserted_at])
    create index(:reports, [:context_type, :context_reference])

    create constraint(:reports, :reports_reporter_not_target,
             check: "reporter_user_id <> reported_user_id"
           )

    create constraint(:reports, :reports_status_valid,
             check:
               "status IN ('submitted', 'triaged', 'under_review', 'resolved', 'dismissed', 'withdrawn')"
           )

    create constraint(:reports, :reports_severity_level_range,
             check: "severity_level >= 1 AND severity_level <= 5"
           )

    create constraint(:reports, :reports_source_valid,
             check: "source IN ('in_app', 'support', 'system', 'web')"
           )

    create constraint(:reports, :reports_incident_type_valid,
             check:
               "incident_type IN ('safety', 'conduct', 'fraud', 'payment', 'vehicle', 'account', 'other')"
           )

    create constraint(:reports, :reports_context_type_valid,
             check:
               "context_type IS NULL OR context_type IN ('ride', 'delivery', 'subscription', 'profile', 'other')"
           )

    create constraint(:reports, :reports_resolution_outcome_valid,
             check:
               "resolution_outcome IS NULL OR resolution_outcome IN ('no_action', 'warning', 'temporary_suspension', 'permanent_ban', 'escalated')"
           )

    create constraint(:reports, :reports_resolved_at_presence,
             check: "resolved_at IS NULL OR status IN ('resolved', 'dismissed', 'withdrawn')"
           )

    create table(:report_evidence) do
      add :report_id, references(:reports, on_delete: :delete_all), null: false
      add :evidence_type, :string, null: false
      add :storage_key, :string, null: false
      add :mime_type, :string
      add :file_size_bytes, :bigint
      add :checksum_sha256, :string
      add :captured_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:report_evidence, [:report_id, :inserted_at])
    create index(:report_evidence, [:evidence_type])

    create constraint(:report_evidence, :report_evidence_type_valid,
             check:
               "evidence_type IN ('image', 'video', 'audio', 'document', 'text', 'system_log')"
           )

    create constraint(:report_evidence, :report_evidence_file_size_non_negative,
             check: "file_size_bytes IS NULL OR file_size_bytes >= 0"
           )

    create table(:report_reviews) do
      add :report_id, references(:reports, on_delete: :delete_all), null: false
      add :reviewer_user_id, references(:users, on_delete: :restrict), null: false
      add :decision, :string, null: false
      add :severity_level, :integer
      add :reason_code, :string
      add :notes, :text
      add :decided_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:report_reviews, [:report_id, :decided_at])
    create index(:report_reviews, [:reviewer_user_id, :decided_at])

    create constraint(:report_reviews, :report_reviews_decision_valid,
             check:
               "decision IN ('needs_more_info', 'no_action', 'warning', 'temporary_suspension', 'permanent_ban', 'escalate', 'dismiss')"
           )

    create constraint(:report_reviews, :report_reviews_severity_level_range,
             check: "severity_level IS NULL OR (severity_level >= 1 AND severity_level <= 5)"
           )

    create table(:user_enforcements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :report_id, references(:reports, on_delete: :nilify_all)
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :scope, :string, null: false, default: "platform"
      add :action, :string, null: false
      add :status, :string, null: false, default: "active"
      add :reason_code, :string
      add :reason_text, :text
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec
      add :lifted_at, :utc_datetime_usec
      add :lifted_by_user_id, references(:users, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_enforcements, [:user_id, :status, :starts_at])
    create index(:user_enforcements, [:report_id])
    create index(:user_enforcements, [:action, :status, :ends_at])
    create index(:user_enforcements, [:status, :ends_at])

    create unique_index(:user_enforcements, [:user_id],
             where: "status = 'active' AND action = 'permanent_ban'",
             name: :user_enforcements_one_active_permanent_ban_per_user
           )

    create constraint(:user_enforcements, :user_enforcements_scope_valid,
             check: "scope IN ('platform', 'rides', 'delivery', 'payments', 'communication')"
           )

    create constraint(:user_enforcements, :user_enforcements_action_valid,
             check:
               "action IN ('warning', 'feature_restriction', 'temporary_suspension', 'permanent_ban')"
           )

    create constraint(:user_enforcements, :user_enforcements_status_valid,
             check: "status IN ('active', 'expired', 'lifted', 'rejected')"
           )

    create constraint(:user_enforcements, :user_enforcements_temporal_window_valid,
             check: "ends_at IS NULL OR ends_at > starts_at"
           )

    create constraint(:user_enforcements, :user_enforcements_temporary_requires_end,
             check: "action <> 'temporary_suspension' OR ends_at IS NOT NULL"
           )

    create constraint(:user_enforcements, :user_enforcements_permanent_without_end,
             check: "action <> 'permanent_ban' OR ends_at IS NULL"
           )

    create constraint(:user_enforcements, :user_enforcements_lifted_at_valid,
             check: "lifted_at IS NULL OR lifted_at >= starts_at"
           )
  end
end
