defmodule Liddr.Rides.DispatchWorkerTest do
  use Liddr.DataCase, async: false

  alias Liddr.Rides.DispatchWorker

  test "worker exits when ride is not found" do
    {:ok, pid} = DispatchWorker.start_link(ride_id: -1)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
