defmodule Liddr.Location.SupplyIndexTest do
  use Liddr.DataCase, async: false

  alias Liddr.Location.SupplyIndex
  alias Liddr.TestS2
  alias Liddr.TestSupport.FakeRedis

  test "candidate lookup degrades gracefully when S2 covering is unavailable" do
    previous_s2_module = Application.get_env(:liddr, :location_s2_module)
    previous_redis_module = Application.get_env(:liddr, :location_redis_module)
    previous_mode = Application.get_env(:liddr, TestS2)

    on_exit(fn ->
      restore_env(:location_s2_module, previous_s2_module)
      restore_env(:location_redis_module, previous_redis_module)
      restore_env(TestS2, previous_mode)
    end)

    Application.put_env(:liddr, :location_s2_module, TestS2)
    Application.put_env(:liddr, :location_redis_module, FakeRedis)
    Application.put_env(:liddr, TestS2, mode: {:error, :s2_covering_unavailable})
    FakeRedis.reset!()

    assert {:error, :supply_index_unavailable} =
             SupplyIndex.candidate_driver_ids(3, -1.2921, 36.8219, 2.0, 10)
  end

  test "upsert_driver indexes candidates without requiring a previous redis snapshot" do
    previous_s2_module = Application.get_env(:liddr, :location_s2_module)
    previous_redis_module = Application.get_env(:liddr, :location_redis_module)
    previous_mode = Application.get_env(:liddr, TestS2)
    previous_token = Application.get_env(:liddr, TestS2)[:token]

    on_exit(fn ->
      restore_env(:location_s2_module, previous_s2_module)
      restore_env(:location_redis_module, previous_redis_module)
      restore_env(TestS2, previous_mode)
    end)

    Application.put_env(:liddr, :location_s2_module, TestS2)
    Application.put_env(:liddr, :location_redis_module, FakeRedis)

    Application.put_env(:liddr, TestS2,
      mode: {:ok, ["182f10dc"]},
      token: previous_token || "182f10dc"
    )

    FakeRedis.reset!()

    assert :ok = SupplyIndex.upsert_driver(42, 3, -1.2921, 36.8219, DateTime.utc_now())
    assert {:ok, [42]} = SupplyIndex.candidate_driver_ids(3, -1.2921, 36.8219, 2.0, 10)
  end

  test "upsert_driver leaves the previous zone when the driver changes cell" do
    previous_redis_module = Application.get_env(:liddr, :location_redis_module)
    on_exit(fn -> restore_env(:location_redis_module, previous_redis_module) end)

    Application.put_env(:liddr, :location_redis_module, FakeRedis)
    FakeRedis.reset!()
    now = DateTime.utc_now()

    assert :ok = SupplyIndex.upsert_driver(42, 3, -1.2921, 36.8219, now, "cell_a")
    assert :ok = SupplyIndex.upsert_driver(42, 3, -1.3000, 36.8500, now, "cell_b")

    assert zone_members("cell_a", 3) == []
    assert zone_members("cell_b", 3) == ["42"]

    assert :ok = SupplyIndex.remove_driver(42)
    assert zone_members("cell_b", 3) == []
  end

  test "upsert_driver keeps the driver in the zone when the cell is unchanged" do
    previous_redis_module = Application.get_env(:liddr, :location_redis_module)
    on_exit(fn -> restore_env(:location_redis_module, previous_redis_module) end)

    Application.put_env(:liddr, :location_redis_module, FakeRedis)
    FakeRedis.reset!()
    now = DateTime.utc_now()

    assert :ok = SupplyIndex.upsert_driver(42, 3, -1.2921, 36.8219, now, "cell_a")
    assert :ok = SupplyIndex.upsert_driver(42, 3, -1.2922, 36.8220, now, "cell_a")

    assert zone_members("cell_a", 3) == ["42"]
  end

  defp zone_members(cell_token, category_id) do
    {:ok, members} = FakeRedis.command(["SMEMBERS", "zone:#{cell_token}:supply:#{category_id}"])
    members
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
