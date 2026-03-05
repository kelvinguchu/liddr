defmodule Liddr.Rides.SharedRideStop do
  use Ecto.Schema
  import Ecto.Changeset

  @stop_types ~w(pickup dropoff)
  @statuses ~w(pending completed skipped cancelled)

  schema "shared_ride_stops" do
    field :group_id, :id
    field :ride_id, :id
    field :member_id, :id
    field :stop_type, :string
    field :status, :string, default: "pending"
    field :sequence, :integer
    field :lat, :decimal
    field :lng, :decimal
    field :eta_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(stop, attrs) do
    stop
    |> cast(attrs, [
      :group_id,
      :ride_id,
      :member_id,
      :stop_type,
      :status,
      :sequence,
      :lat,
      :lng,
      :eta_at,
      :completed_at,
      :metadata
    ])
    |> validate_required([:group_id, :ride_id, :stop_type, :status, :sequence, :lat, :lng])
    |> validate_inclusion(:stop_type, @stop_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:sequence, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:member_id)
    |> unique_constraint([:group_id, :sequence])
    |> check_constraint(:stop_type, name: :shared_ride_stops_stop_type_valid)
    |> check_constraint(:status, name: :shared_ride_stops_status_valid)
    |> check_constraint(:lat, name: :shared_ride_stops_lat_range)
    |> check_constraint(:lng, name: :shared_ride_stops_lng_range)
  end
end
