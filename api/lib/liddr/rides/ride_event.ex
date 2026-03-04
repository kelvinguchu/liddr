defmodule Liddr.Rides.RideEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "ride_events" do
    field :ride_id, :id
    field :actor_user_id, :id
    field :event_type, :string
    field :payload, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [:ride_id, :actor_user_id, :event_type, :payload, :occurred_at])
    |> validate_required([:ride_id, :event_type, :occurred_at])
    |> update_change(:event_type, &String.trim/1)
    |> validate_length(:event_type, min: 1, max: 80)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:actor_user_id)
    |> check_constraint(:event_type, name: :ride_events_event_type_non_empty)
  end
end
