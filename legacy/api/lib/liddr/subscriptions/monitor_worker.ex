defmodule Liddr.Subscriptions.MonitorWorker do
  @moduledoc false

  use Oban.Worker, queue: :subscriptions, max_attempts: 5

  import Ecto.Query

  alias Liddr.Location.DriverHotState
  alias Liddr.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired_subscriptions_query =
      from(s in "subscriptions",
        where: s.status in ["active", "grace"] and s.week_end < ^today
      )

    {_expired_count, _updated_rows} =
      Repo.update_all(expired_subscriptions_query,
        set: [status: "expired", expired_at: now, updated_at: now]
      )

    inactive_drivers_query =
      from(d in "drivers",
        where:
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM subscriptions s
              WHERE s.driver_id = ? AND s.status = 'expired'
            )
            AND NOT EXISTS (
              SELECT 1
              FROM subscriptions sa
              WHERE sa.driver_id = ? AND sa.status IN ('active', 'grace')
            )
            """,
            d.user_id,
            d.user_id
          )
      )

    driver_ids_to_invalidate = Repo.all(from(d in inactive_drivers_query, select: d.user_id))

    {_driver_count, _updated_driver_rows} =
      Repo.update_all(inactive_drivers_query,
        set: [subscription_status: "inactive", is_available: false, updated_at: now]
      )

    :ok = DriverHotState.invalidate_many(driver_ids_to_invalidate)

    :ok
  end
end
