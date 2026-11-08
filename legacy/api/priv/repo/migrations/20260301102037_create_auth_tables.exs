defmodule Liddr.Repo.Migrations.CreateAuthTables do
  use Ecto.Migration

  def change do
    create table(:otp_requests) do
      add :phone, :string, null: false
      add :purpose, :string, null: false
      add :otp_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :attempts, :integer, null: false, default: 0
      add :requested_by_ip, :string
      add :requested_by_device, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:otp_requests, [:phone, :inserted_at])
    create index(:otp_requests, [:phone, :purpose, :expires_at])

    create constraint(:otp_requests, :otp_requests_attempts_non_negative, check: "attempts >= 0")

    create constraint(:otp_requests, :otp_requests_purpose_valid,
             check: "purpose IN ('driver_login', 'passenger_login')"
           )

    create table(:refresh_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :issued_by_ip, :string
      add :issued_by_device, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:refresh_tokens, [:token_hash])
    create index(:refresh_tokens, [:user_id, :inserted_at])
    create index(:refresh_tokens, [:expires_at])
  end
end
