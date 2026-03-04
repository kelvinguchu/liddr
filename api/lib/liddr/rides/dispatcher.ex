defmodule Liddr.Rides.Dispatcher do
  alias Liddr.Rides.DispatchWorker

  @registry Liddr.Rides.DispatchRegistry
  @supervisor Liddr.Rides.DispatchSupervisor

  def ensure_started(ride_id, opts \\ []) do
    case lookup_pid(ride_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        child_spec = {DispatchWorker, Keyword.put(opts, :ride_id, ride_id)}

        case DynamicSupervisor.start_child(@supervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> error
        end
    end
  end

  def dispatch_now(ride_id) do
    case lookup_pid(ride_id) do
      {:ok, pid} -> GenServer.call(pid, :dispatch_now, 15_000)
      :error -> :ok
    end
  end

  def stop(ride_id) do
    case lookup_pid(ride_id) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal)
        :ok

      :error ->
        :ok
    end
  end

  defp lookup_pid(ride_id) do
    case Registry.lookup(@registry, ride_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
