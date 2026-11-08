defmodule Liddr.Moderation do
  alias Liddr.Moderation.ActionRateLimiter
  alias Liddr.Moderation.Categories
  alias Liddr.Moderation.EnforcementLifecycle
  alias Liddr.Moderation.Enforcements
  alias Liddr.Moderation.Reports

  defdelegate enforce_report_create_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_report_create

  defdelegate enforce_report_triage_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_report_triage

  defdelegate enforce_report_review_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_report_review

  defdelegate enforce_message_report_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_ride_message_report

  defdelegate enforce_dispute_ops_resolution_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_dispute_ops_resolution

  defdelegate list_report_categories(attrs \\ %{}), to: Categories
  defdelegate submit_report(attrs), to: Reports
  defdelegate list_reports(attrs \\ %{}), to: Reports
  defdelegate triage_report(report_id, attrs, reviewer_user_id), to: Reports
  defdelegate review_report(report_id, attrs, reviewer_user_id), to: Reports
  defdelegate apply_enforcement(attrs), to: Enforcements
  defdelegate list_enforcements(attrs \\ %{}), to: Enforcements
  defdelegate enforcement_metrics(attrs \\ %{}), to: Enforcements
  defdelegate expire_due_temporary_suspensions(attrs \\ %{}), to: EnforcementLifecycle
end
