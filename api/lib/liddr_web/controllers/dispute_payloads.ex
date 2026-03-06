defmodule LiddrWeb.DisputePayloads do
  def report(report) do
    %{
      id: report.id,
      ride_id: ride_id_from_context(report.context_reference),
      dispute_type: dispute_type_from_metadata(report.metadata),
      status: report.status,
      reporter_user_id: report.reporter_user_id,
      reported_user_id: report.reported_user_id,
      category_id: report.category_id,
      incident_type: report.incident_type,
      severity_level: report.severity_level,
      description: report.description,
      resolution_outcome: report.resolution_outcome,
      resolution_summary: report.resolution_summary,
      inserted_at: report.inserted_at,
      resolved_at: report.resolved_at
    }
  end

  def resolution(payload) do
    %{
      report: report(payload.report),
      review: %{
        id: payload.review.id,
        decision: payload.review.decision,
        reason_code: payload.review.reason_code,
        notes: payload.review.notes,
        metadata: payload.review.metadata,
        decided_at: payload.review.decided_at
      },
      enforcement: payload.enforcement,
      resolution_outcome: payload.resolution_outcome,
      compensation: compensation(payload.compensation)
    }
  end

  def compensation(nil), do: nil

  def compensation(compensation) do
    %{
      id: compensation.id,
      report_id: compensation.report_id,
      ride_id: compensation.ride_id,
      beneficiary_user_id: compensation.beneficiary_user_id,
      counterparty_user_id: compensation.counterparty_user_id,
      actor_user_id: compensation.actor_user_id,
      compensation_type: compensation.compensation_type,
      status: compensation.status,
      amount_kes: compensation.amount_kes,
      currency: compensation.currency,
      reason_code: compensation.reason_code,
      reason_text: compensation.reason_text,
      processed_at: compensation.processed_at,
      processed_by_user_id: compensation.processed_by_user_id,
      processing_reference: compensation.processing_reference,
      processing_channel: compensation.processing_channel,
      inserted_at: compensation.inserted_at
    }
  end

  defp dispute_type_from_metadata(%{} = metadata),
    do: Map.get(metadata, "dispute_type") || Map.get(metadata, :dispute_type)

  defp dispute_type_from_metadata(_), do: nil

  defp ride_id_from_context(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ride_id, ""} when ride_id > 0 -> ride_id
      _ -> nil
    end
  end

  defp ride_id_from_context(_), do: nil
end
