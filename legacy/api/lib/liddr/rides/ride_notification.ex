defmodule Liddr.Rides.RideNotification do
  use Ecto.Schema
  import Ecto.Changeset

  @delivery_statuses ~w(pending sent acked failed)

  schema "ride_notifications" do
    field :ride_id, :id
    field :recipient_user_id, :id
    field :event_type, :string
    field :socket_status, :string, default: "pending"
    field :push_status, :string, default: "pending"
    field :poll_status, :string, default: "pending"
    field :last_attempt_at, :utc_datetime_usec
    field :acked_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :ride_id,
      :recipient_user_id,
      :event_type,
      :socket_status,
      :push_status,
      :poll_status,
      :last_attempt_at,
      :acked_at,
      :attempt_count,
      :payload
    ])
    |> validate_required([:ride_id, :recipient_user_id, :event_type])
    |> update_change(:event_type, &String.trim/1)
    |> validate_length(:event_type, min: 1, max: 80)
    |> validate_inclusion(:socket_status, @delivery_statuses)
    |> validate_inclusion(:push_status, @delivery_statuses)
    |> validate_inclusion(:poll_status, @delivery_statuses)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:recipient_user_id)
    |> check_constraint(:event_type, name: :ride_notifications_event_type_non_empty)
    |> check_constraint(:socket_status, name: :ride_notifications_socket_status_valid)
    |> check_constraint(:push_status, name: :ride_notifications_push_status_valid)
    |> check_constraint(:poll_status, name: :ride_notifications_poll_status_valid)
    |> check_constraint(:attempt_count, name: :ride_notifications_attempt_count_non_negative)
  end
end
