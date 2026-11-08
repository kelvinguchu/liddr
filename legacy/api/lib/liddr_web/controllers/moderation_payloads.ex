defmodule LiddrWeb.ModerationPayloads do
  def report(report) do
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

  def review(review) do
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

  def enforcement(enforcement) do
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
end
