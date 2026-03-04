defmodule Liddr.Rides.RideDestinationChange do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested accepted rejected expired)

  schema "ride_destination_changes" do
    field :ride_id, :id
    field :requested_by_user_id, :id
    field :driver_id, :id
    field :old_dropoff_lat, :decimal
    field :old_dropoff_lng, :decimal
    field :new_dropoff_lat, :decimal
    field :new_dropoff_lng, :decimal
    field :old_fare_kes, :decimal
    field :new_fare_kes, :decimal
    field :fare_delta_kes, :decimal
    field :status, :string
    field :reason_code, :string
    field :notes, :string
    field :requested_at, :utc_datetime_usec
    field :responded_at, :utc_datetime_usec
    field :pricing_payload, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(change, attrs) do
    change
    |> cast(attrs, [
      :ride_id,
      :requested_by_user_id,
      :driver_id,
      :old_dropoff_lat,
      :old_dropoff_lng,
      :new_dropoff_lat,
      :new_dropoff_lng,
      :old_fare_kes,
      :new_fare_kes,
      :fare_delta_kes,
      :status,
      :reason_code,
      :notes,
      :requested_at,
      :responded_at,
      :pricing_payload
    ])
    |> validate_required([
      :ride_id,
      :requested_by_user_id,
      :driver_id,
      :old_dropoff_lat,
      :old_dropoff_lng,
      :new_dropoff_lat,
      :new_dropoff_lng,
      :old_fare_kes,
      :new_fare_kes,
      :fare_delta_kes,
      :status,
      :reason_code,
      :requested_at
    ])
    |> update_change(:reason_code, &String.trim/1)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:old_fare_kes, greater_than_or_equal_to: 0)
    |> validate_number(:new_fare_kes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:requested_by_user_id)
    |> foreign_key_constraint(:driver_id)
    |> unique_constraint(:ride_id, name: :ride_destination_changes_one_open_per_ride)
    |> check_constraint(:status, name: :ride_destination_changes_status_valid)
    |> check_constraint(:reason_code, name: :ride_destination_changes_reason_non_empty)
    |> check_constraint(:old_fare_kes, name: :ride_destination_changes_money_non_negative)
    |> check_constraint(:responded_at, name: :ride_destination_changes_responded_when_closed)
    |> check_constraint(:old_dropoff_lat, name: :ride_destination_changes_old_dropoff_lat_range)
    |> check_constraint(:old_dropoff_lng, name: :ride_destination_changes_old_dropoff_lng_range)
    |> check_constraint(:new_dropoff_lat, name: :ride_destination_changes_new_dropoff_lat_range)
    |> check_constraint(:new_dropoff_lng, name: :ride_destination_changes_new_dropoff_lng_range)
  end
end
