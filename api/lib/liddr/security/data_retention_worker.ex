defmodule Liddr.Security.DataRetentionWorker do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  alias Liddr.Security.DataRetention

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    results = DataRetention.run()

    Logger.info(
      "[security.retention] auth_challenges_deleted=#{results.auth_challenges_deleted} idempotency_requests_deleted=#{results.idempotency_requests_deleted} webhook_events_deleted=#{results.webhook_events_deleted}"
    )

    :ok
  end
end
