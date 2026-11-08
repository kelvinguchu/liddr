defmodule Liddr.Rides.PickupWatchdogWorker do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Liddr.Rides

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _ = Rides.run_pickup_watchdog(args)
    :ok
  end
end
