defmodule Liddr.Rides.SharedRides.Context do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.SharedRideGroup
  alias Liddr.Rides.SharedRideMember
  alias Liddr.Rides.SharedRideStop
  alias Liddr.Rides.Timeline

  def for_user(user_id, ride_id) do
    with {:ok, ride} <- Timeline.get_ride_for_user(user_id, ride_id),
         :ok <- ensure_shared_ride(ride) do
      {:ok, for_ride!(ride.id, ride)}
    end
  end

  def for_ride!(ride_id, ride \\ nil) do
    group = Repo.get_by(SharedRideGroup, ride_id: ride_id)

    members =
      from(m in SharedRideMember,
        where: m.ride_id == ^ride_id,
        order_by: [asc: m.inserted_at, asc: m.id]
      )
      |> Repo.all()

    stops =
      from(s in SharedRideStop,
        where: s.ride_id == ^ride_id,
        order_by: [asc: s.sequence, asc: s.id]
      )
      |> Repo.all()

    %{ride: ride, group: group, members: members, stops: stops}
  end

  def ensure_shared_ride(%{product_type: "shared"}), do: :ok
  def ensure_shared_ride(_ride), do: {:error, :shared_not_enabled_for_ride}
end
