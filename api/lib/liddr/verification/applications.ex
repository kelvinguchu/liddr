defmodule Liddr.Verification.Applications do
  alias Liddr.Verification.Applications.Query
  alias Liddr.Verification.Applications.Review

  def list_applications(attrs \\ %{}), do: Query.list_applications(attrs)

  def review_application(application_id, attrs, reviewer_user_id),
    do: Review.review_application(application_id, attrs, reviewer_user_id)
end
