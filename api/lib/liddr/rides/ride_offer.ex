defmodule Liddr.Rides.RideOffer do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(offered accepted rejected expired withdrawn)

  schema "ride_offers" do
    field :status, :string
    field :offered_at, :utc_datetime_usec
    field :responded_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :ride_id, :id
    field :driver_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(offer, attrs) do
    offer
    |> cast(attrs, [
      :ride_id,
      :driver_id,
      :status,
      :offered_at,
      :responded_at,
      :expires_at,
      :metadata
    ])
    |> validate_required([:ride_id, :driver_id, :status, :offered_at, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:ride_id)
    |> foreign_key_constraint(:driver_id)
    |> unique_constraint(:driver_id, name: :ride_offers_ride_id_driver_id_index)
    |> check_constraint(:status, name: :ride_offers_status_valid)
    |> check_constraint(:expires_at, name: :ride_offers_temporal_window_valid)
  end
end
