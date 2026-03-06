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

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
