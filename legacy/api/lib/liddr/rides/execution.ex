defmodule Liddr.Rides.Execution do
  alias Liddr.Rides.Execution.Cancellation
  alias Liddr.Rides.Execution.Completion
  alias Liddr.Rides.Execution.DriverFlow
  alias Liddr.Rides.Execution.Reassignment

  defdelegate mark_driver_arriving(driver_user_id, ride_id), to: DriverFlow
  defdelegate mark_driver_arrived(driver_user_id, ride_id), to: DriverFlow
  defdelegate start_ride(driver_user_id, ride_id), to: DriverFlow
  defdelegate pickup_health(rider_user_id, ride_id), to: Reassignment
  defdelegate request_reassign(rider_user_id, ride_id, attrs \\ %{}), to: Reassignment
  defdelegate complete_ride(driver_user_id, ride_id, attrs \\ %{}), to: Completion
  defdelegate rider_cancel_ride(rider_user_id, ride_id, attrs \\ %{}), to: Cancellation
  defdelegate driver_cancel_ride(driver_user_id, ride_id, attrs \\ %{}), to: Cancellation
  defdelegate mark_rider_no_show(driver_user_id, ride_id, attrs \\ %{}), to: Cancellation
end
