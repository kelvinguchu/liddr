defmodule Liddr.Location.S2NativeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Liddr.Location.S2
  alias Liddr.Location.S2Native

  @pool S2Native.Pool

  setup do
    previous_config = Application.get_env(:liddr, S2Native)

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:liddr, S2Native)
        config -> Application.put_env(:liddr, S2Native, config)
      end
    end)

    :ok
  end

  test "covering lookup reports an error when the helper times out" do
    workers =
      for {_partition, pid, _type, _modules} <- PartitionSupervisor.which_children(@pool), do: pid

    Enum.each(workers, &:sys.suspend/1)
    on_exit(fn -> Enum.each(workers, &:sys.resume/1) end)
    Application.put_env(:liddr, S2Native, request_timeout_ms: 20)

    assert {:error, :s2_covering_unavailable} = S2.covering_tokens(-1.2921, 36.8219, 2.0, 10)
  end

  test "covering lookup reports an error when the helper pool is not running" do
    :ok = Supervisor.terminate_child(Liddr.Supervisor, S2Native)
    on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Liddr.Supervisor, S2Native) end)

    assert {:error, :s2_covering_unavailable} = S2.covering_tokens(-1.2921, 36.8219, 2.0, 10)
  end

  test "startup is skipped instead of failing when the helper cannot be built" do
    Application.put_env(:liddr, S2Native, helper_path: "/proc/liddr-missing/s2cover")

    log =
      capture_log(fn ->
        assert :ignore = S2Native.start_link([])
      end)

    assert log =~ "helper unavailable"
  end
end
