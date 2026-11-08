defmodule Liddr.Rides.ActiveRides do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Ride

  @driver_active_statuses ~w(accepted driver_arriving arrived in_progress)

  def driver_active_statuses, do: @driver_active_statuses

  def active_ride_id_for_driver(driver_user_id, opts \\ [])

  def active_ride_id_for_driver(driver_user_id, opts) when is_integer(driver_user_id) do
    except_ride_id = Keyword.get(opts, :except_ride_id)

    Ride
    |> where(
      [ride],
      ride.driver_id == ^driver_user_id and ride.status in ^@driver_active_statuses
    )
    |> maybe_exclude_ride(except_ride_id)
    |> order_by([ride], desc: ride.accepted_at, desc: ride.inserted_at)
    |> limit(1)
    |> select([ride], ride.id)
    |> Repo.one()
  end

  def active_ride_id_for_driver(_driver_user_id, _opts), do: nil

  def driver_has_active_ride?(driver_user_id, opts \\ []) do
    is_integer(active_ride_id_for_driver(driver_user_id, opts))
  end

  defp maybe_exclude_ride(query, except_ride_id) when is_integer(except_ride_id) do
    where(query, [ride], ride.id != ^except_ride_id)
  end

  defp maybe_exclude_ride(query, _except_ride_id), do: query
end
