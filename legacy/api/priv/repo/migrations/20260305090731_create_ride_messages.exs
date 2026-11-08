defmodule Liddr.Repo.Migrations.CreateRideMessages do
  use Ecto.Migration

  def change do
    create table(:ride_messages) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :sender_user_id, references(:users, on_delete: :nothing), null: false
      add :recipient_user_id, references(:users, on_delete: :nothing), null: false
      add :sender_role, :string, null: false
      add :message_type, :string, null: false
      add :body, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :read_at, :utc_datetime_usec
      add :acked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ride_messages, [:ride_id, :id])
    create index(:ride_messages, [:recipient_user_id, :read_at])
    create index(:ride_messages, [:ride_id, :inserted_at])

    create constraint(:ride_messages, :ride_messages_sender_role_valid,
             check: "sender_role IN ('rider','driver','system')"
           )

    create constraint(:ride_messages, :ride_messages_type_valid,
             check: "message_type IN ('text','quick_action','system')"
           )

    create constraint(:ride_messages, :ride_messages_non_empty_body,
             check: "char_length(trim(body)) > 0"
           )

    create constraint(:ride_messages, :ride_messages_read_before_ack,
             check: "acked_at IS NULL OR read_at IS NOT NULL"
           )
  end
end
