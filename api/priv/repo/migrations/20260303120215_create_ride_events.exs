defmodule Liddr.Repo.Migrations.CreateRideEvents do
  use Ecto.Migration

  def change do
    create table(:ride_events) do
      add :ride_id, references(:rides, on_delete: :delete_all), null: false
      add :actor_user_id, references(:users, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:ride_events, [:ride_id, :occurred_at])
    create index(:ride_events, [:ride_id, :event_type, :occurred_at])
    create index(:ride_events, [:actor_user_id, :occurred_at])

    create constraint(:ride_events, :ride_events_event_type_non_empty,
             check: "char_length(trim(event_type)) > 0"
           )
  end
end
