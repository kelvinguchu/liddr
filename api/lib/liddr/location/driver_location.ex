defmodule Liddr.Location.DriverLocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:driver_id, :id, autogenerate: false}
  @foreign_key_type :id

  schema "driver_locations" do
    field :lat, :decimal
    field :lng, :decimal
    field :captured_at, :utc_datetime_usec
    field :s2_cell_token, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(location, attrs) do
    location
    |> cast(attrs, [:driver_id, :lat, :lng, :captured_at, :s2_cell_token, :metadata])
    |> validate_required([:driver_id, :lat, :lng, :captured_at])
    |> foreign_key_constraint(:driver_id)
    |> check_constraint(:lat, name: :driver_locations_lat_range)
    |> check_constraint(:lng, name: :driver_locations_lng_range)
  end
end
