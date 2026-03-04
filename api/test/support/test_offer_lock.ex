defmodule Liddr.TestOfferLock do
  @moduledoc false

  @behaviour Liddr.Rides.DriverOfferLock

  @impl true
  def acquire(driver_id, _ride_id, _ttl_seconds) do
    locked_driver_ids = Application.get_env(:liddr, __MODULE__, [])[:locked_driver_ids] || []

    if driver_id in locked_driver_ids, do: :locked, else: :acquired
  end

  @impl true
  def release(driver_id, ride_id) do
    if is_pid(test_pid()) do
      send(test_pid(), {:test_offer_lock_released, driver_id, ride_id})
    end

    :ok
  end

  defp test_pid do
    Application.get_env(:liddr, __MODULE__, [])[:test_pid]
  end
end
