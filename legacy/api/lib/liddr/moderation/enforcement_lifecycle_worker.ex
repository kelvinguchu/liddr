defmodule Liddr.Moderation.EnforcementLifecycleWorker do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Liddr.Moderation

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    _ = Moderation.expire_due_temporary_suspensions(args)
    :ok
  end
end
