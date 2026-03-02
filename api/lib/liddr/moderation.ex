defmodule Liddr.Moderation do
  alias Liddr.Moderation.Categories
  alias Liddr.Moderation.EnforcementLifecycle
  alias Liddr.Moderation.Enforcements
  alias Liddr.Moderation.Reports

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
