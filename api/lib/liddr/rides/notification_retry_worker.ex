defmodule Liddr.Rides.NotificationRetryWorker do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Liddr.Rides.NotificationRetry

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _ = NotificationRetry.run(args)
    :ok
  end
end
