defmodule Liddr.Rides.DriverOfferLock.Redis do
  @moduledoc false

  @behaviour Liddr.Rides.DriverOfferLock

  alias Liddr.Location.Redis, as: LocationRedis

  @unlock_script """
  if redis.call("GET", KEYS[1]) == ARGV[1] then
    return redis.call("DEL", KEYS[1])
  else
    return 0
  end
  """

  @impl true
  def acquire(driver_id, ride_id, ttl_seconds)
      when is_integer(driver_id) and driver_id > 0 and is_integer(ride_id) and ride_id > 0 and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    case LocationRedis.command([
           "SET",
           lock_key(driver_id),
           lock_value(ride_id),
           "NX",
           "EX",
           Integer.to_string(ttl_seconds)
         ]) do
      {:ok, "OK"} -> :acquired
      {:ok, nil} -> :locked
      {:error, _reason} -> :unavailable
    end
  end

  def acquire(_driver_id, _ride_id, _ttl_seconds), do: :unavailable

  @impl true
  def release(driver_id, ride_id)
      when is_integer(driver_id) and driver_id > 0 and is_integer(ride_id) and ride_id > 0 do
    _ =
      LocationRedis.command([
        "EVAL",
        @unlock_script,
        "1",
        lock_key(driver_id),
        lock_value(ride_id)
      ])

    :ok
  end

  def release(_driver_id, _ride_id), do: :ok

  defp lock_key(driver_id), do: "rides:offer_lock:driver:#{driver_id}"
  defp lock_value(ride_id), do: "ride:#{ride_id}"
end
