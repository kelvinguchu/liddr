defmodule Liddr.Repo.Migrations.AddMessageModerationFlagsToRideMessages do
  use Ecto.Migration

  def change do
    alter table(:ride_messages) do
      add :hidden_for_sender_at, :utc_datetime_usec
      add :hidden_for_recipient_at, :utc_datetime_usec
    end

    create index(:ride_messages, [:ride_id, :sender_user_id, :hidden_for_sender_at],
             name: :ride_messages_sender_visibility_idx
           )

    create index(:ride_messages, [:ride_id, :recipient_user_id, :hidden_for_recipient_at],
             name: :ride_messages_recipient_visibility_idx
           )
  end
end
