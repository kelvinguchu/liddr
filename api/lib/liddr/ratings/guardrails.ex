defmodule Liddr.Ratings.Guardrails do
  import Ecto.Query

  alias Liddr.Ratings.Policy
  alias Liddr.Ratings.Rating
  alias Liddr.Repo

  def enforcement_snapshot_for_user(rated_user_id, now) do
    cutoff =
      now
      |> DateTime.add(-Policy.enforcement_recent_window_days() * 86_400, :second)
      |> DateTime.truncate(:microsecond)

    recent_count =
      Repo.one(
        from r in Rating,
          where:
            r.rated_user_id == ^rated_user_id and r.include_in_score == true and
              is_nil(r.nullified_at) and r.submitted_at >= ^cutoff,
          select: count(r.id)
      ) || 0

    minimum_required = Policy.enforcement_min_recent_ratings()

    %{
      rated_user_id: rated_user_id,
      recent_attributable_ratings: recent_count,
      minimum_required: minimum_required,
      window_days: Policy.enforcement_recent_window_days(),
      ready?: recent_count >= minimum_required
    }
  end
end
