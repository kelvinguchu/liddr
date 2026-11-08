defmodule Liddr.Rides.SharedRides.Access do
  @moduledoc false

  import Ecto.Query

  def scope_for_user(query, user_id) do
    from r in query,
      where:
        r.rider_id == ^user_id or r.driver_id == ^user_id or
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM shared_ride_members m
              WHERE m.ride_id = ? AND m.rider_user_id = ?
            )
            """,
            r.id,
            ^user_id
          )
  end

  def rider_scope(query, rider_user_id) do
    from r in query,
      where:
        r.rider_id == ^rider_user_id or
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM shared_ride_members m
              WHERE m.ride_id = ? AND m.rider_user_id = ?
            )
            """,
            r.id,
            ^rider_user_id
          )
  end
end
