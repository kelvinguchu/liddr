defmodule Liddr.Disputes do
  alias Liddr.Moderation.ActionRateLimiter
  alias Liddr.Disputes.Cases

  defdelegate enforce_submit_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_dispute_create

  defdelegate enforce_ops_resolution_rate_limit(user_id),
    to: ActionRateLimiter,
    as: :enforce_dispute_ops_resolution

  defdelegate submit_for_ride(requester_user_id, attrs), to: Cases
  defdelegate list_for_user(user_id, attrs \\ %{}), to: Cases
  defdelegate list_for_ops(attrs \\ %{}), to: Cases
  defdelegate resolve_for_ops(report_id, reviewer_user_id, attrs \\ %{}), to: Cases

  defdelegate list_compensations_for_user(user_id, attrs \\ %{}),
    to: Liddr.Disputes.Compensations,
    as: :list_for_user

  defdelegate list_compensations_for_ops(attrs \\ %{}),
    to: Liddr.Disputes.Compensations,
    as: :list_for_ops

  defdelegate mark_compensation_paid(compensation_id, actor_user_id, attrs \\ %{}),
    to: Liddr.Disputes.Compensations,
    as: :mark_paid

  defdelegate cancel_compensation(compensation_id, actor_user_id, attrs \\ %{}),
    to: Liddr.Disputes.Compensations,
    as: :cancel
end
