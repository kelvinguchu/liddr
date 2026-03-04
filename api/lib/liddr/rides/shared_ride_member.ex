defmodule Liddr.Rides.SharedRideMember do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(requested assigned pickup_pending picked_up dropoff_pending dropped_off cancelled no_show)

  schema "shared_ride_members" do
    field :group_id, :id
    field :ride_id, :id
    field :rider_user_id, :id
    field :status, :string, default: "requested"
    field :requested_at, :utc_datetime_usec
    field :picked_up_at, :utc_datetime_usec
    field :dropped_off_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :no_show_marked_at, :utc_datetime_usec
    field :cancellation_reason_code, :string
    field :cancelled_by_user_id, :id
    field :fare_kes, :decimal
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(member, attrs) do
    member
    |> cast(attrs, [
      :group_id,
      :ride_id,
      :rider_user_id,
      :status,
      :requested_at,
      :picked_up_at,
      :dropped_off_at,
      :cancelled_at,
      :no_show_marked_at,
      :cancellation_reason_code,
      :cancelled_by_user_id,
      :fare_kes,
      :metadata
    ])
    |> validate_required([:group_id, :ride_id, :rider_user_id, :status, :requested_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:fare_kes, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:rider_user_id)
    |> foreign_key_constraint(:cancelled_by_user_id)
    |> unique_constraint([:group_id, :rider_user_id])
    |> check_constraint(:status, name: :shared_ride_members_status_valid)
    |> check_constraint(:fare_kes, name: :shared_ride_members_fare_non_negative)
    |> check_constraint(:status, name: :shared_ride_members_cancelled_when_cancelled)
    |> check_constraint(:status, name: :shared_ride_members_no_show_when_no_show)
  end
end
