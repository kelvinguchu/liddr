defmodule Liddr.Rides.Integrity.ModeLifecycleWorker do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Liddr.Rides

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _ = Rides.expire_due_rider_prepay_modes(args)
    :ok
  end
end
