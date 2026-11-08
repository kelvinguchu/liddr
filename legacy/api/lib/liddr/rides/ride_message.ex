defmodule Liddr.Rides.RideMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @sender_roles ~w(rider driver system)
  @message_types ~w(text quick_action system)

  schema "ride_messages" do
    field :ride_id, :id
    field :sender_user_id, :id
    field :recipient_user_id, :id
    field :sender_role, :string
    field :message_type, :string
    field :body, :string
    field :metadata, :map, default: %{}
    field :read_at, :utc_datetime_usec
    field :acked_at, :utc_datetime_usec
    field :hidden_for_sender_at, :utc_datetime_usec
    field :hidden_for_recipient_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [
      :ride_id,
      :sender_user_id,
      :recipient_user_id,
      :sender_role,
      :message_type,
      :body,
      :metadata,
      :read_at,
      :acked_at,
      :hidden_for_sender_at,
      :hidden_for_recipient_at
    ])
    |> validate_required([
      :ride_id,
      :sender_user_id,
      :recipient_user_id,
      :sender_role,
      :message_type,
      :body
    ])
    |> update_change(:sender_role, &normalize/1)
    |> update_change(:message_type, &normalize/1)
    |> update_change(:body, &String.trim/1)
    |> validate_inclusion(:sender_role, @sender_roles)
    |> validate_inclusion(:message_type, @message_types)
    |> validate_length(:body, min: 1, max: 1_000)
    |> validate_sender_recipient_difference()
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:sender_user_id)
    |> foreign_key_constraint(:recipient_user_id)
    |> check_constraint(:sender_role, name: :ride_messages_sender_role_valid)
    |> check_constraint(:message_type, name: :ride_messages_type_valid)
    |> check_constraint(:body, name: :ride_messages_non_empty_body)
    |> check_constraint(:acked_at, name: :ride_messages_read_before_ack)
  end

  def mark_read_changeset(message, attrs) do
    message
    |> cast(attrs, [:read_at, :acked_at])
    |> validate_required([:read_at])
    |> maybe_set_acked_from_read()
    |> check_constraint(:acked_at, name: :ride_messages_read_before_ack)
  end

  def hide_for_user_changeset(message, attrs) do
    message
    |> cast(attrs, [:hidden_for_sender_at, :hidden_for_recipient_at])
  end

  def moderation_changeset(message, attrs) do
    message
    |> cast(attrs, [:metadata, :hidden_for_sender_at, :hidden_for_recipient_at])
  end

  defp maybe_set_acked_from_read(changeset) do
    read_at = get_field(changeset, :read_at)
    acked_at = get_field(changeset, :acked_at)

    if is_nil(acked_at) and match?(%DateTime{}, read_at) do
      put_change(changeset, :acked_at, read_at)
    else
      changeset
    end
  end

  defp validate_sender_recipient_difference(changeset) do
    sender = get_field(changeset, :sender_user_id)
    recipient = get_field(changeset, :recipient_user_id)

    if is_integer(sender) and is_integer(recipient) and sender == recipient do
      add_error(changeset, :recipient_user_id, "must differ from sender")
    else
      changeset
    end
  end

  defp normalize(nil), do: nil
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
