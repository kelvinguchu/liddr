defmodule Liddr.Rides.Trips do
  alias Liddr.Rides.Execution

  defdelegate complete_ride(driver_user_id, ride_id, attrs \\ %{}), to: Execution
end
