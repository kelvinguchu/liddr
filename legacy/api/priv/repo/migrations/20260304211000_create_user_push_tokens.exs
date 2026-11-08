defmodule Liddr.Repo.Migrations.CreateUserPushTokens do
  use Ecto.Migration

  def change do
    create table(:user_push_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false, default: "fcm"
      add :platform, :string, null: false
      add :token, :string, null: false
      add :device_id, :string
      add :last_seen_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_push_tokens, [:user_id])
    create unique_index(:user_push_tokens, [:token], name: :user_push_tokens_token_unique)

    create index(:user_push_tokens, [:user_id, :provider, :revoked_at],
             name: :user_push_tokens_active_lookup_idx
           )

    create constraint(:user_push_tokens, :user_push_tokens_provider_valid,
             check: "provider IN ('fcm')"
           )

    create constraint(:user_push_tokens, :user_push_tokens_platform_valid,
             check: "platform IN ('android', 'ios', 'web')"
           )

    create constraint(:user_push_tokens, :user_push_tokens_token_non_empty,
             check: "char_length(trim(token)) > 0"
           )
  end
end
