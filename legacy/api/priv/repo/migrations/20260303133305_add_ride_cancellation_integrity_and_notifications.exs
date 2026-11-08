defmodule Liddr.Repo.Migrations.AddRideCancellationIntegrityAndNotifications do
  use Ecto.Migration

  def change do
    alter table(:rides) do
      add :cancellation_reason_code, :string
      add :cancelled_by_user_id, references(:users, on_delete: :nilify_all)
      add :no_show_marked_at, :utc_datetime_usec
    end

    create index(:rides, [:cancelled_by_user_id, :cancelled_at])
    create index(:rides, [:no_show_marked_at])

    create table(:ride_notifications) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :recipient_user_id, references(:users, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :socket_status, :string, null: false, default: "pending"
      add :push_status, :string, null: false, default: "pending"
      add :poll_status, :string, null: false, default: "pending"
      add :last_attempt_at, :utc_datetime_usec
      add :acked_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ride_notifications, [:ride_id, :event_type, :inserted_at])
    create index(:ride_notifications, [:recipient_user_id, :event_type, :inserted_at])
    create index(:ride_notifications, [:socket_status, :updated_at])

    create constraint(:ride_notifications, :ride_notifications_event_type_non_empty,
             check: "char_length(trim(event_type)) > 0"
           )

    create constraint(:ride_notifications, :ride_notifications_socket_status_valid,
             check: "socket_status IN ('pending', 'sent', 'acked', 'failed')"
           )

    create constraint(:ride_notifications, :ride_notifications_push_status_valid,
             check: "push_status IN ('pending', 'sent', 'acked', 'failed')"
           )

    create constraint(:ride_notifications, :ride_notifications_poll_status_valid,
             check: "poll_status IN ('pending', 'sent', 'acked', 'failed')"
           )

    create constraint(:ride_notifications, :ride_notifications_attempt_count_non_negative,
             check: "attempt_count >= 0"
           )
  end
end
