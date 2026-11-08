defmodule Liddr.Verification.Documents.ReviewWorkflow do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Location.DriverHotState
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationReview

  @document_reviewable_statuses ~w(uploaded pending_review resubmission_required)

  def review_document_locked(parsed_document_id, decision, attrs, reviewer_user_id, now) do
    document =
      Repo.one(
        from(d in VerificationDocument,
          where: d.id == ^parsed_document_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:document_not_found)

    application =
      Repo.one(
        from(a in VerificationApplication,
          where: a.id == ^document.application_id,
          lock: "FOR UPDATE"
        )
      ) || Repo.rollback(:application_not_found)

    driver = Repo.get(Driver, document.driver_id) || Repo.rollback(:driver_profile_not_found)

    if document.status in @document_reviewable_statuses and scan_clean?(document) do
      updated_document =
        document
        |> Ecto.Changeset.change(document_updates_for_decision(decision, attrs, now))
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      updated_application =
        application
        |> VerificationApplication.create_changeset(
          application_updates_for_document_decision(application, decision, attrs, now)
        )
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      updated_driver =
        driver
        |> Driver.create_changeset(driver_updates_for_document_decision(driver, decision, now))
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end

      :ok = DriverHotState.put(updated_driver)

      review =
        %VerificationReview{}
        |> VerificationReview.create_changeset(%{
          "application_id" => updated_application.id,
          "driver_id" => updated_driver.user_id,
          "reviewer_user_id" => reviewer_user_id,
          "decision" => decision,
          "reason" => Shared.get_value(attrs, :reason),
          "decided_at" => now,
          "metadata" => %{"document_id" => updated_document.id}
        })
        |> Repo.insert()
        |> case do
          {:ok, created} -> created
          {:error, changeset} -> Repo.rollback(changeset)
        end

      _activity =
        %DriverActivityEvent{}
        |> DriverActivityEvent.create_changeset(%{
          "driver_id" => updated_driver.user_id,
          "event_type" => "verification_updated",
          "previous_value" => document.status,
          "new_value" => updated_document.status,
          "reason_code" => "document_#{decision}",
          "reason_text" => Shared.get_value(attrs, :reason),
          "actor_type" => "ops",
          "actor_user_id" => reviewer_user_id,
          "payload" => %{
            "application_id" => updated_application.id,
            "document_id" => updated_document.id,
            "decision" => decision
          }
        })
        |> Repo.insert()
        |> case do
          {:ok, event} -> event
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %{
        document: updated_document,
        application: updated_application,
        driver: updated_driver,
        review: review
      }
    else
      if document.status in @document_reviewable_statuses do
        Repo.rollback(:document_not_scanned_clean)
      else
        Repo.rollback(:document_not_reviewable)
      end
    end
  end

  defp document_updates_for_decision("approve", _attrs, now) do
    %{
      status: "validated",
      reviewed_at: now,
      rejection_reason: nil
    }
  end

  defp document_updates_for_decision("reject", attrs, now) do
    %{
      status: "rejected",
      reviewed_at: now,
      rejection_reason: Shared.get_value(attrs, :reason)
    }
  end

  defp application_updates_for_document_decision(application, "approve", _attrs, now) do
    cond do
      application.status == "pending" ->
        %{
          "status" => "under_review",
          "submitted_at" => application.submitted_at || now
        }

      true ->
        %{
          "status" => application.status
        }
    end
  end

  defp application_updates_for_document_decision(_application, "reject", attrs, _now) do
    %{
      "status" => "resubmission_required",
      "decision_reason" => Shared.get_value(attrs, :reason),
      "decided_at" => nil
    }
  end

  defp driver_updates_for_document_decision(driver, "approve", now) do
    %{
      "verification_status" =>
        if(driver.verification_status in ["pending", "under_review"],
          do: "under_review",
          else: driver.verification_status
        ),
      "last_seen_at" => now
    }
  end

  defp driver_updates_for_document_decision(driver, "reject", now) do
    base = %{
      "verification_status" => "pending",
      "last_seen_at" => now
    }

    case driver.account_status do
      "suspended" -> base
      "deactivated" -> base
      _ -> Map.put(base, "account_status", "pending")
    end
  end

  defp scan_clean?(%{scan_status: scan_status}), do: scan_status in ["clean", "skipped"]
end
