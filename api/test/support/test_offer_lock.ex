defmodule Liddr.TestOfferLock do
  @moduledoc false

  @behaviour Liddr.Rides.DriverOfferLock

  @impl true
  def acquire(driver_id, _ride_id, _ttl_seconds) do
    config = Application.get_env(:liddr, __MODULE__, [])
    locked_driver_ids = config[:locked_driver_ids] || []
    unavailable_driver_ids = config[:unavailable_driver_ids] || []

    cond do
      driver_id in unavailable_driver_ids -> :unavailable
      driver_id in locked_driver_ids -> :locked
      true -> :acquired
    end
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
