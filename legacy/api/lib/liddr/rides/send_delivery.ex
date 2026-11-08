defmodule Liddr.Rides.SendDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @item_sizes ~w(small medium large)
  @payers ~w(sender recipient)
  @payment_timings ~w(before after)
  @confirmation_statuses ~w(pending confirmed expired)
  @delivery_statuses ~w(
    pending_pickup
    in_transit
    delivered_pending_confirmation
    delivered_confirmed
    completed
  )

  schema "send_deliveries" do
    field :sender_name, :string
    field :sender_phone, :string
    field :recipient_name, :string
    field :recipient_phone, :string
    field :item_description, :string
    field :item_size, :string
    field :payer, :string
    field :payment_timing, :string
    field :item_value_kes, :decimal
    field :special_instructions, :string
    field :liability_acknowledged, :boolean, default: false
    field :prohibited_item_warnings, :map, default: %{}
    field :pickup_proof_key, :string
    field :pickup_proof_captured_at, :utc_datetime_usec
    field :dropoff_proof_key, :string
    field :dropoff_proof_captured_at, :utc_datetime_usec
    field :recipient_confirmation_token_hash, :string
    field :recipient_confirmation_expires_at, :utc_datetime_usec
    field :recipient_confirmed_at, :utc_datetime_usec
    field :recipient_confirmation_status, :string, default: "pending"
    field :delivery_status, :string, default: "pending_pickup"
    field :ride_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(send_delivery, attrs) do
    send_delivery
    |> cast(attrs, [
      :ride_id,
      :sender_name,
      :sender_phone,
      :recipient_name,
      :recipient_phone,
      :item_description,
      :item_size,
      :payer,
      :payment_timing,
      :item_value_kes,
      :special_instructions,
      :liability_acknowledged,
      :prohibited_item_warnings,
      :pickup_proof_key,
      :pickup_proof_captured_at,
      :dropoff_proof_key,
      :dropoff_proof_captured_at,
      :recipient_confirmation_token_hash,
      :recipient_confirmation_expires_at,
      :recipient_confirmed_at,
      :recipient_confirmation_status,
      :delivery_status
    ])
    |> validate_required([
      :ride_id,
      :sender_name,
      :recipient_name,
      :recipient_phone,
      :item_description,
      :item_size,
      :payer,
      :payment_timing
    ])
    |> validate_inclusion(:item_size, @item_sizes)
    |> validate_inclusion(:payer, @payers)
    |> validate_inclusion(:payment_timing, @payment_timings)
    |> validate_inclusion(:recipient_confirmation_status, @confirmation_statuses)
    |> validate_inclusion(:delivery_status, @delivery_statuses)
    |> validate_number(:item_value_kes, greater_than_or_equal_to: 0)
    |> unique_constraint(:ride_id)
    |> unique_constraint(:recipient_confirmation_token_hash)
    |> foreign_key_constraint(:ride_id)
    |> check_constraint(:item_size, name: :send_deliveries_item_size_valid)
    |> check_constraint(:payer, name: :send_deliveries_payer_valid)
    |> check_constraint(:payment_timing, name: :send_deliveries_payment_timing_valid)
    |> check_constraint(:recipient_confirmation_status,
      name: :send_deliveries_recipient_confirmation_status_valid
    )
    |> check_constraint(:delivery_status, name: :send_deliveries_delivery_status_valid)
    |> check_constraint(:item_value_kes, name: :send_deliveries_item_value_non_negative)
  end
end
