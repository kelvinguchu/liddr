defmodule Liddr.Rides.MessageAbuseEscalation do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Moderation.Enforcements
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Ratings.SignalReports
  alias Liddr.Repo
  alias Liddr.Rides.MessageModerationPolicy

  @message_abuse_report_reason_code "message_abuse_auto_restriction"
  @signal_category_candidates ~w(harassment_or_abuse other)
  @communication_restriction_actions ~w(feature_restriction temporary_suspension permanent_ban)

  def ensure_can_send(user_id) do
    if communication_restricted?(user_id) do
      {:error, :ride_message_communication_restricted}
    else
      :ok
    end
  end

  def maybe_auto_escalate!(reported_user_id, report_id, now) do
    report_count = recent_reported_message_count(reported_user_id, now)
    threshold = MessageModerationPolicy.auto_restrict_threshold()
    existing = active_communication_restriction(reported_user_id, now)

    cond do
      report_count < threshold ->
        %{
          "state" => "below_threshold",
          "reported_message_count" => report_count,
          "threshold" => threshold
        }

      match?(%UserEnforcement{}, existing) ->
        %{
          "state" => "already_restricted",
          "enforcement_id" => existing.id,
          "reported_message_count" => report_count,
          "threshold" => threshold
        }

      true ->
        enforcement =
          apply_communication_restriction!(reported_user_id, report_id, report_count, now)

        signal_status =
          emit_message_abuse_signal(reported_user_id, report_count, enforcement, now)

        %{
          "state" => "auto_restricted",
          "enforcement_id" => enforcement.id,
          "signal_status" => signal_status,
          "reported_message_count" => report_count,
          "threshold" => threshold
        }
    end
  end

  defp recent_reported_message_count(reported_user_id, now) do
    cutoff = DateTime.add(now, -MessageModerationPolicy.report_window_days() * 86_400, :second)

    Repo.one(
      from r in Report,
        where:
          r.reported_user_id == ^reported_user_id and r.context_type == "ride" and
            like(r.context_reference, "ride_message:%") and r.inserted_at >= ^cutoff,
        select: count(r.id)
    ) || 0
  end

  defp active_communication_restriction(user_id, now) do
    Repo.one(
      from ue in UserEnforcement,
        where:
          ue.user_id == ^user_id and ue.scope == "communication" and ue.status == "active" and
            ue.action in ^@communication_restriction_actions and
            (is_nil(ue.ends_at) or ue.ends_at > ^now),
        order_by: [desc: ue.inserted_at, desc: ue.id],
        limit: 1
    )
  end

  defp communication_restricted?(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    match?(%UserEnforcement{}, active_communication_restriction(user_id, now))
  end

  defp apply_communication_restriction!(reported_user_id, report_id, report_count, now) do
    Enforcements.apply_enforcement_in_transaction!(%{
      "user_id" => reported_user_id,
      "report_id" => report_id,
      "scope" => "communication",
      "action" => "feature_restriction",
      "reason_code" => @message_abuse_report_reason_code,
      "reason_text" => "Auto communication restriction after repeated reported ride messages",
      "starts_at" => now,
      "metadata" => %{
        "source" => "ride_message_auto_escalation",
        "reported_message_count" => report_count,
        "window_days" => MessageModerationPolicy.report_window_days()
      }
    })
  end

  defp emit_message_abuse_signal(reported_user_id, report_count, enforcement, now) do
    case SignalReports.create_system_report(%{
           now: now,
           reported_user_id: reported_user_id,
           category_candidates: @signal_category_candidates,
           cooldown_days: MessageModerationPolicy.signal_cooldown_days(),
           context_reference: "message_abuse_signal:#{reported_user_id}",
           severity_level: 4,
           incident_type: "conduct",
           description:
             "Auto communication restriction applied after repeated reported ride messages.",
           metadata: %{
             "message_abuse_signal_code" => "ride_message_auto_restriction",
             "reported_message_count" => report_count,
             "enforcement_id" => enforcement.id,
             "window_days" => MessageModerationPolicy.report_window_days()
           }
         }) do
      {:ok, status} -> to_string(status)
      _ -> "signal_create_skipped"
    end
  end
end
