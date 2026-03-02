defmodule Liddr.Verification.ExpiryMonitorWorker do
  @moduledoc false

  use Oban.Worker, queue: :verification, max_attempts: 5

  import Ecto.Query

  alias Liddr.Repo

  @expirable_document_statuses [
    "uploaded",
    "pending_review",
    "validated",
    "resubmission_required"
  ]
  @active_driver_statuses ["pending", "active"]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired_docs_query =
      from(d in "verification_documents",
        join: r in "verification_requirements",
        on: r.document_type == d.document_type,
        where:
          r.is_active == true and r.required == true and r.requires_expiry == true and
            d.status in ^@expirable_document_statuses and not is_nil(d.expires_on) and
            d.expires_on < ^today
      )

    {_expired_doc_count, _updated_docs} =
      Repo.update_all(expired_docs_query, set: [status: "expired", updated_at: now])

    drivers_to_suspend_query =
      from(d in "drivers",
        where: d.account_status in ^@active_driver_statuses,
        where:
          fragment(
            """
            EXISTS (
              SELECT 1
              FROM verification_documents vd
              JOIN verification_requirements vr ON vr.document_type = vd.document_type
              WHERE vd.driver_id = ?
                AND vr.is_active = true
                AND vr.required = true
                AND vr.requires_expiry = true
                AND vd.status = 'expired'
            )
            """,
            d.user_id
          ),
        select: d.user_id
      )

    driver_ids_to_suspend = Repo.all(drivers_to_suspend_query)

    if driver_ids_to_suspend != [] do
      suspend_query =
        from(d in "drivers",
          where: d.user_id in ^driver_ids_to_suspend
        )

      {_suspended_count, _updated_drivers} =
        Repo.update_all(suspend_query,
          set: [
            account_status: "suspended",
            verification_status: "suspended",
            is_available: false,
            suspended_at: now,
            updated_at: now
          ]
        )

      activity_events =
        Enum.map(driver_ids_to_suspend, fn driver_id ->
          %{
            driver_id: driver_id,
            event_type: "verification_updated",
            previous_value: "active_or_pending",
            new_value: "suspended",
            reason_code: "document_expired",
            reason_text: "One or more required verification documents are expired.",
            actor_type: "system",
            payload: %{"source" => "verification_expiry_monitor"},
            inserted_at: now
          }
        end)

      Repo.insert_all("driver_activity_events", activity_events)
    end

    :ok
  end
end
