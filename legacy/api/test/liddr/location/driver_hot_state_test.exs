defmodule Liddr.Location.DriverHotStateTest do
  use Liddr.DataCase, async: false

  alias Liddr.Location.DriverHotState
  alias Liddr.Repo

  @driver_id 987_654

  setup do
    DriverHotState.invalidate(@driver_id)
    on_exit(fn -> DriverHotState.invalidate(@driver_id) end)
    :ok
  end

  test "touch_last_seen updates last seen without extending the cache TTL" do
    :ok = DriverHotState.put(snapshot("active"))
    [{@driver_id, expires_at_ms, _snapshot, _last_seen_at}] = cache_entry()
    last_seen_at = DateTime.utc_now()

    :ok = DriverHotState.touch_last_seen(@driver_id, last_seen_at)

    assert [{@driver_id, ^expires_at_ms, _snapshot, ^last_seen_at}] = cache_entry()
    assert {:ok, %{last_seen_at: ^last_seen_at}} = DriverHotState.fetch(@driver_id)
  end

  test "touch_last_seen keeps a newer snapshot written during the ping" do
    :ok = DriverHotState.put(snapshot("active"))
    :ok = DriverHotState.put(snapshot("suspended"))

    :ok = DriverHotState.touch_last_seen(@driver_id, DateTime.utc_now())

    assert {:ok, %{account_status: "suspended"}} = DriverHotState.fetch(@driver_id)
  end

  test "touch_last_seen does not create a cache entry" do
    :ok = DriverHotState.touch_last_seen(@driver_id, DateTime.utc_now())

    assert cache_entry() == []
  end

  test "put inside a transaction clears the cache instead of storing uncommitted state" do
    :ok = DriverHotState.put(snapshot("active"))

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               :ok = DriverHotState.put(snapshot("suspended"))
               Repo.rollback(:rolled_back)
             end)

    assert cache_entry() == []
  end

  defp cache_entry, do: :ets.lookup(DriverHotState, @driver_id)

  defp snapshot(account_status) do
    %{
      user_id: @driver_id,
      vehicle_category_id: 1,
      subscription_status: "active",
      is_available: true,
      account_status: account_status,
      verification_status: "approved",
      last_seen_at: nil,
      current_ride_id: nil,
      dispatch_status: "idle"
    }
  end
end
