defmodule Liddr.Ratings do
  alias Liddr.Ratings.Actions
  alias Liddr.Ratings.Guardrails
  alias Liddr.Ratings.Ops
  alias Liddr.Ratings.Submission

  defdelegate rate_ride(rated_by_user_id, ride_id, attrs \\ %{}), to: Submission
  defdelegate skip_ride_rating(rated_by_user_id, ride_id), to: Submission
  defdelegate enqueue_for_completed_ride!(ride, now), to: Actions
  defdelegate list_pending_for_user(user_id, now), to: Actions
  defdelegate list_ratings(attrs \\ %{}), to: Ops
  defdelegate list_excluded_ratings(attrs \\ %{}), to: Ops
  defdelegate nullify_rating(rating_id, attrs, actor_user_id), to: Ops
  defdelegate reinstate_rating(rating_id, attrs, actor_user_id), to: Ops
  defdelegate enforcement_snapshot_for_user(rated_user_id, now), to: Guardrails
end
