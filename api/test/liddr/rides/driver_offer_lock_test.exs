defmodule Liddr.Rides.DriverOfferLockTest do
  use Liddr.DataCase, async: false

  alias Liddr.Rides.DriverOfferLock
  alias Liddr.TestOfferLock

  @acquire_event [:liddr, :rides, :offer_lock, :acquire]
  @release_event [:liddr, :rides, :offer_lock, :release]

  setup do
    previous_impl = Application.get_env(:liddr, :ride_offer_lock)
    previous_test_opts = Application.get_env(:liddr, TestOfferLock)

    Application.put_env(:liddr, :ride_offer_lock, TestOfferLock)
    Application.put_env(:liddr, TestOfferLock, test_pid: self(), locked_driver_ids: [2])

    on_exit(fn ->
      restore_env(:ride_offer_lock, previous_impl)
      restore_env(TestOfferLock, previous_test_opts)
    end)

    :ok
  end

  test "acquire_many emits telemetry for acquired and locked outcomes" do
    handler_id = "driver-offer-lock-acquire-#{System.unique_integer([:positive])}"
    attach_telemetry_handler!(handler_id, @acquire_event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result = DriverOfferLock.acquire_many([1, 2, 3], 9001, 30, source: "dispatch_wave")

    assert result.selected_driver_ids == [1, 3]
    assert result.locked_driver_ids == [1, 3]
    assert result.locked_count == 1
    assert result.acquired_count == 2
    assert result.unavailable_count == 0

    assert_receive {:offer_lock_telemetry, @acquire_event, %{count: 1},
                    %{source: "dispatch_wave", result: :acquired}},
                   1_000

    assert_receive {:offer_lock_telemetry, @acquire_event, %{count: 1},
                    %{source: "dispatch_wave", result: :locked}},
                   1_000
  end

  test "release_many deduplicates pairs and emits release telemetry count" do
    handler_id = "driver-offer-lock-release-#{System.unique_integer([:positive])}"
    attach_telemetry_handler!(handler_id, @release_event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      DriverOfferLock.release_many(
        [
          {11, 71},
          {11, 71},
          %{driver_id: 12, ride_id: 71},
          %{"driver_id" => 13, "ride_id" => 71},
          :invalid
        ],
        source: "offer_reject"
      )

    assert_receive {:offer_lock_telemetry, @release_event, %{count: 3},
                    %{source: "offer_reject"}},
                   1_000

    assert_receive {:test_offer_lock_released, 11, 71}, 1_000
    assert_receive {:test_offer_lock_released, 12, 71}, 1_000
    assert_receive {:test_offer_lock_released, 13, 71}, 1_000
  end

  defp attach_telemetry_handler!(handler_id, event_name) do
    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn name, measurements, metadata, _config ->
          send(self(), {:offer_lock_telemetry, name, measurements, metadata})
        end,
        nil
      )
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)
end
