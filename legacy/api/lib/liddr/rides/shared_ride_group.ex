defmodule Liddr.Rides.SharedRideGroup do
  use Ecto.Schema
  import Ecto.Changeset

  schema "shared_ride_groups" do
    field :ride_id, :id
    field :max_members, :integer, default: 2
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:ride_id, :max_members, :metadata])
    |> validate_required([:ride_id, :max_members])
    |> validate_number(:max_members, greater_than_or_equal_to: 2, less_than_or_equal_to: 6)
    |> foreign_key_constraint(:ride_id)
    |> unique_constraint(:ride_id)
    |> check_constraint(:max_members, name: :shared_ride_groups_max_members_valid)
  end
end
