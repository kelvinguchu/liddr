defmodule Liddr.Repo.Migrations.AddAuthV2Foundations do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email, :string
      add :email_verified_at, :utc_datetime_usec
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL")

    drop constraint(:users, :users_role_valid)

    create constraint(:users, :users_role_valid,
             check: "role IN ('driver', 'passenger', 'ops', 'admin')"
           )

    create table(:user_roles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :granted_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :granted_by_user_id, references(:users, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:user_roles, [:user_id, :role])
    create index(:user_roles, [:role, :inserted_at])

    create unique_index(:user_roles, [:user_id, :role],
             where: "revoked_at IS NULL",
             name: :user_roles_one_active_role_per_user
           )

    create constraint(:user_roles, :user_roles_role_valid,
             check: "role IN ('rider', 'driver', 'ops', 'admin')"
           )

    create table(:auth_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :identifier, :string, null: false
      add :identifier_normalized, :string, null: false
      add :secret_hash, :string
      add :secret_salt, :string
      add :verified_at, :utc_datetime_usec
      add :disabled_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:auth_identities, [:provider, :identifier_normalized])
    create index(:auth_identities, [:user_id, :provider])
    create index(:auth_identities, [:provider, :verified_at])

    create unique_index(:auth_identities, [:user_id, :provider],
             where: "provider = 'totp' AND disabled_at IS NULL",
             name: :auth_identities_one_active_totp_per_user
           )

    create constraint(:auth_identities, :auth_identities_provider_valid,
             check:
               "provider IN ('phone_otp', 'email_otp', 'email_password', 'google', 'apple', 'totp')"
           )

    create constraint(:auth_identities, :auth_identities_secret_required_for_sensitive_providers,
             check: "provider NOT IN ('email_password', 'totp') OR secret_hash IS NOT NULL"
           )

    create table(:auth_challenges) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :identity_value, :string, null: false
      add :purpose, :string, null: false
      add :channel, :string, null: false
      add :code_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :max_attempts, :integer, null: false, default: 5
      add :locked_until, :utc_datetime_usec
      add :requested_by_ip, :string
      add :requested_by_device, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:auth_challenges, [:provider, :identity_value, :purpose, :inserted_at])
    create index(:auth_challenges, [:expires_at])
    create index(:auth_challenges, [:user_id, :inserted_at])

    create constraint(:auth_challenges, :auth_challenges_provider_valid,
             check:
               "provider IN ('phone_otp', 'email_otp', 'email_password', 'google', 'apple', 'totp')"
           )

    create constraint(:auth_challenges, :auth_challenges_purpose_valid,
             check:
               "purpose IN ('login', 'register_driver', 'register_rider', 'step_up', 'recover_account', 'reset_password')"
           )

    create constraint(:auth_challenges, :auth_challenges_channel_valid,
             check: "channel IN ('sms', 'email', 'totp', 'push')"
           )

    create constraint(:auth_challenges, :auth_challenges_attempts_non_negative,
             check: "attempts >= 0"
           )

    create constraint(:auth_challenges, :auth_challenges_max_attempts_positive,
             check: "max_attempts >= 1"
           )

    create constraint(:auth_challenges, :auth_challenges_attempts_within_limit,
             check: "attempts <= max_attempts"
           )

    create table(:auth_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :session_family_id, :uuid, null: false
      add :session_token_hash, :string, null: false
      add :refresh_token_hash, :string, null: false
      add :auth_method, :string, null: false
      add :issued_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :revoked_reason, :string
      add :replaced_by_session_id, references(:auth_sessions, on_delete: :nilify_all)
      add :issued_by_ip, :string
      add :issued_by_device, :string
      add :issued_by_user_agent, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:auth_sessions, [:session_token_hash])
    create unique_index(:auth_sessions, [:refresh_token_hash])
    create index(:auth_sessions, [:user_id, :revoked_at, :expires_at])
    create index(:auth_sessions, [:session_family_id, :inserted_at])
    create index(:auth_sessions, [:expires_at])

    create constraint(:auth_sessions, :auth_sessions_auth_method_valid,
             check:
               "auth_method IN ('phone_otp', 'email_otp', 'email_password', 'google', 'apple', 'totp', 'step_up')"
           )
  end
end
