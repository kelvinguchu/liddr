defmodule Liddr.Location.DriverHotStateWarmup do
  @moduledoc false

  use GenServer

  require Logger

  alias Liddr.Location.DriverHotState

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    {:ok, %{}, {:continue, :prewarm}}
  end

  @impl true
  def handle_continue(:prewarm, state) do
    started_at = System.monotonic_time()
    :ok = DriverHotState.prewarm()

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Logger.info("[location.driver_hot_state] prewarm complete duration_ms=#{duration_ms}")
    {:noreply, state}
  end
end
