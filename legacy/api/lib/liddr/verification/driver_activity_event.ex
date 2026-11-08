defmodule Liddr.Verification.DriverActivityEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @event_types ~w(status_changed went_online went_offline subscription_updated verification_updated)
  @actor_types ~w(system driver ops)

  schema "driver_activity_events" do
    field :event_type, :string
    field :previous_value, :string
    field :new_value, :string
    field :reason_code, :string
    field :reason_text, :string
    field :actor_type, :string
    field :payload, :map, default: %{}

    field :driver_id, :id

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    belongs_to :actor_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :driver_id,
      :event_type,
      :previous_value,
      :new_value,
      :reason_code,
      :reason_text,
      :actor_type,
      :actor_user_id,
      :payload
    ])
    |> validate_required([:driver_id, :event_type, :actor_type])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:actor_type, @actor_types)
    |> foreign_key_constraint(:driver_id)
    |> foreign_key_constraint(:actor_user_id)
    |> check_constraint(:event_type, name: :driver_activity_events_event_type_valid)
    |> check_constraint(:actor_type, name: :driver_activity_events_actor_type_valid)
  end
end
