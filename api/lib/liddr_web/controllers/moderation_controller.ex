defmodule LiddrWeb.ModerationController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Moderation

  def list_reports(conn, params) do
    reports = Moderation.list_reports(params) |> Enum.map(&report_payload/1)
    json(conn, %{data: %{reports: reports}})
  end

  def triage_report(conn, %{"id" => report_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    case Moderation.triage_report(report_id, params, reviewer_user_id) do
      {:ok, report} ->
        json(conn, %{data: report_payload(report)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def review_report(conn, %{"id" => report_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    case Moderation.review_report(report_id, params, reviewer_user_id) do
      {:ok, %{report: report, review: review}} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            report: report_payload(report),
            review: review_payload(review)
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def create_enforcement(conn, params) do
    actor_id = conn.assigns.current_user.id
    payload = Map.put(params, "actor_user_id", actor_id)

    case Moderation.apply_enforcement(payload) do
      {:ok, enforcement} ->
        conn
        |> put_status(:created)
        |> json(%{data: enforcement_payload(enforcement)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def list_enforcements(conn, params) do
    enforcements = Moderation.list_enforcements(params) |> Enum.map(&enforcement_payload/1)
    json(conn, %{data: %{enforcements: enforcements}})
  end

  def enforcement_metrics(conn, params) do
    case Moderation.enforcement_metrics(params) do
      {:ok, metrics} ->
        json(conn, %{data: metrics})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def reconcile_enforcements(conn, params) do
    with {:ok, limit} <- parse_reconciliation_limit(params),
         {:ok, results} <- Moderation.expire_due_temporary_suspensions(%{limit: limit}) do
      expired_count = Enum.count(results, &(&1.status == "expired"))

      json(conn, %{
        data: %{
          processed: length(results),
          expired: expired_count,
          results: results
        }
      })
    else
      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp report_payload(report) do
    %{
      id: report.id,
      reporter_user_id: report.reporter_user_id,
      reported_user_id: report.reported_user_id,
      reported_driver_id: report.reported_driver_id,
      category_id: report.category_id,
      status: report.status,
      severity_level: report.severity_level,
      source: report.source,
      incident_type: report.incident_type,
      context_type: report.context_type,
      context_reference: report.context_reference,
      incident_at: report.incident_at,
      description: report.description,
      assigned_reviewer_user_id: report.assigned_reviewer_user_id,
      triaged_at: report.triaged_at,
      resolved_at: report.resolved_at,
      resolution_outcome: report.resolution_outcome,
      resolution_summary: report.resolution_summary,
      inserted_at: report.inserted_at
    }
  end

  defp review_payload(review) do
    %{
      id: review.id,
      report_id: review.report_id,
      reviewer_user_id: review.reviewer_user_id,
      decision: review.decision,
      severity_level: review.severity_level,
      reason_code: review.reason_code,
      notes: review.notes,
      decided_at: review.decided_at,
      inserted_at: review.inserted_at
    }
  end

  defp enforcement_payload(enforcement) do
    %{
      id: enforcement.id,
      user_id: enforcement.user_id,
      report_id: enforcement.report_id,
      actor_user_id: enforcement.actor_user_id,
      scope: enforcement.scope,
      action: enforcement.action,
      status: enforcement.status,
      reason_code: enforcement.reason_code,
      reason_text: enforcement.reason_text,
      starts_at: enforcement.starts_at,
      ends_at: enforcement.ends_at,
      inserted_at: enforcement.inserted_at
    }
  end

  defp render_error(conn, :user_not_found),
    do: error_response(conn, :not_found, "USER_NOT_FOUND", "User not found")

  defp render_error(conn, :report_not_found),
    do: error_response(conn, :not_found, "REPORT_NOT_FOUND", "Report not found")

  defp render_error(conn, :invalid_triage_status),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_TRIAGE_STATUS",
        "Triage status must be triaged or under_review"
      )

  defp render_error(conn, :invalid_review_decision),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_REVIEW_DECISION",
        "Unsupported moderation review decision"
      )

  defp render_error(conn, :report_not_triageable),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORT_NOT_TRIAGEABLE",
        "Report cannot be triaged in its current state"
      )

  defp render_error(conn, :report_not_reviewable),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORT_NOT_REVIEWABLE",
        "Report cannot be reviewed in its current state"
      )

  defp render_error(conn, :missing_enforcement_ends_at),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_ENFORCEMENT_ENDS_AT",
        "Temporary suspension review requires a future ends_at timestamp"
      )

  defp render_error(conn, :invalid_enforcement_ends_at),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_ENFORCEMENT_ENDS_AT",
        "ends_at must be a valid future ISO8601 datetime"
      )

  defp render_error(conn, :invalid_reconciliation_limit),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RECONCILIATION_LIMIT",
        "limit must be an integer between 1 and 1000"
      )

  defp render_error(conn, :invalid_due_within_hours),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DUE_WITHIN_HOURS",
        "due_within_hours must be an integer between 1 and 720"
      )

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, _unknown),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "ENFORCEMENT_ERROR",
        "Unable to apply enforcement"
      )

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp parse_reconciliation_limit(params) do
    value = Map.get(params, "limit") || Map.get(params, :limit)

    case value do
      nil ->
        {:ok, 200}

      parsed when is_integer(parsed) and parsed >= 1 and parsed <= 1000 ->
        {:ok, parsed}

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, ""} when parsed >= 1 and parsed <= 1000 -> {:ok, parsed}
          _ -> {:error, :invalid_reconciliation_limit}
        end

      _ ->
        {:error, :invalid_reconciliation_limit}
    end
  end
end
