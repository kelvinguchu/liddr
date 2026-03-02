defmodule Liddr.Subscriptions.ReconciliationWorker do
  @moduledoc false

  use Oban.Worker, queue: :payments, max_attempts: 5

  alias Liddr.Subscriptions

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _ = Subscriptions.reconcile_pending_payments()
    :ok
  end
end
