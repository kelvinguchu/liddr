defmodule Liddr.Verification.Applications.Review do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Location.DriverHotState
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationReview

  @review_decisions ~w(approve reject request_resubmission suspend)
  @application_reviewable_statuses ~w(pending under_review resubmission_required)

  def review_application(application_id, attrs, reviewer_user_id) do
    with {:ok, decision} <- fetch_review_decision(attrs),
         {:ok, parsed_application_id} <- parse_application_id(application_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        application =
          Repo.one(
            from(a in VerificationApplication,
              where: a.id == ^parsed_application_id,
              lock: "FOR UPDATE"
            )
          ) || Repo.rollback(:application_not_found)

        driver =
          Repo.get(Driver, application.driver_id) || Repo.rollback(:driver_profile_not_found)

        if application.status in @application_reviewable_statuses do
          review =
            %VerificationReview{}
            |> VerificationReview.create_changeset(%{
              "application_id" => application.id,
              "driver_id" => application.driver_id,
              "reviewer_user_id" => reviewer_user_id,
              "decision" => decision,
              "reason" => Shared.get_value(attrs, :reason),
              "decided_at" => now,
              "metadata" => Shared.get_value(attrs, :metadata) || %{}
            })
            |> Repo.insert()
            |> case do
              {:ok, created_review} -> created_review
              {:error, changeset} -> Repo.rollback(changeset)
            end

          updated_application =
            application
            |> VerificationApplication.create_changeset(%{
              "status" => application_status_for_decision(decision),
              "decided_at" => now,
              "decision_reason" => Shared.get_value(attrs, :reason)
            })
            |> Repo.update()
            |> case do
              {:ok, app} -> app
              {:error, changeset} -> Repo.rollback(changeset)
            end

          previous_driver_status = driver.verification_status

          updated_driver =
            driver
            |> Driver.create_changeset(driver_updates_for_decision(driver, decision, now))
            |> Repo.update()
            |> case do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end

          :ok = DriverHotState.put(updated_driver)

          _activity =
            %DriverActivityEvent{}
            |> DriverActivityEvent.create_changeset(%{
              "driver_id" => driver.user_id,
              "event_type" => "verification_updated",
              "previous_value" => previous_driver_status,
              "new_value" => updated_driver.verification_status,
              "reason_code" => decision,
              "reason_text" => Shared.get_value(attrs, :reason),
              "actor_type" => "ops",
              "actor_user_id" => reviewer_user_id,
              "payload" => %{
                "application_id" => updated_application.id,
                "decision" => decision
              }
            })
            |> Repo.insert()
            |> case do
              {:ok, event} -> event
              {:error, changeset} -> Repo.rollback(changeset)
            end

          %{
            application: updated_application,
            review: review,
            driver: updated_driver
          }
        else
          Repo.rollback(:application_not_reviewable)
        end
      end)
      |> Shared.unwrap_transaction_result()
    end
  end

  defp fetch_review_decision(attrs) do
    decision =
      attrs
      |> Shared.get_value(:decision)
      |> Shared.normalize_text()

    if decision in @review_decisions do
      {:ok, decision}
    else
      {:error, :invalid_review_decision}
    end
  end

  defp parse_application_id(application_id) do
    case Shared.parse_integer(application_id) do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, :application_not_found}
    end
  end

  defp application_status_for_decision("approve"), do: "approved"
  defp application_status_for_decision("reject"), do: "rejected"
  defp application_status_for_decision("request_resubmission"), do: "resubmission_required"
  defp application_status_for_decision("suspend"), do: "suspended"

  defp driver_updates_for_decision(driver, "approve", now) do
    base = %{
      "verification_status" => "approved",
      "last_seen_at" => now
    }

    case driver.account_status do
      "pending" ->
        Map.merge(base, %{
          "account_status" => "active",
          "activated_at" => driver.activated_at || now
        })

      _ ->
        base
    end
  end

  defp driver_updates_for_decision(_driver, "reject", now) do
    %{
      "verification_status" => "rejected",
      "account_status" => "pending",
      "last_seen_at" => now
    }
  end

  defp driver_updates_for_decision(_driver, "request_resubmission", now) do
    %{
      "verification_status" => "pending",
      "account_status" => "pending",
      "last_seen_at" => now
    }
  end

  defp driver_updates_for_decision(_driver, "suspend", now) do
    %{
      "verification_status" => "suspended",
      "account_status" => "suspended",
      "is_available" => false,
      "suspended_at" => now,
      "last_seen_at" => now
    }
  end
end
