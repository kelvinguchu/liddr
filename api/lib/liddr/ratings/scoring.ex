defmodule Liddr.Ratings.Scoring do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Ratings.Policy
  alias Liddr.Ratings.Rating
  alias Liddr.Repo

  def recalculate_user_score!(rated_user_id, now) do
    ratings =
      Repo.all(
        from r in Rating,
          where: r.rated_user_id == ^rated_user_id and r.include_in_score == true,
          select: %{score: r.score, submitted_at: r.submitted_at}
      )

    stats = aggregate_stats(ratings, now)
    user = Repo.get(User, rated_user_id) || Repo.rollback(:rated_user_not_found)

    _updated_user =
      user
      |> User.rating_stats_changeset(%{
        "rating_score" => stats.rating_score,
        "rating_count" => stats.rating_count,
        "rating_weighted_sum" => stats.rating_weighted_sum,
        "rating_weight_total" => stats.rating_weight_total
      })
      |> Repo.update()
      |> unwrap_or_rollback()

    stats
  end

  def aggregate_stats(ratings, now) do
    {weighted_sum, weighted_total, rating_count} =
      Enum.reduce(ratings, {0.0, 0.0, 0}, fn rating, {sum, total, count} ->
        weight = recency_weight(rating.submitted_at, now)
        {sum + rating.score * weight, total + weight, count + 1}
      end)

    if rating_count == 0 do
      %{
        rating_score: nil,
        rating_count: 0,
        rating_weighted_sum: D.new("0"),
        rating_weight_total: D.new("0")
      }
    else
      prior_mean = Policy.smoothing_prior_mean()
      prior_weight = Policy.smoothing_prior_weight()

      smoothed_score =
        (weighted_sum + prior_mean * prior_weight) /
          (weighted_total + prior_weight)

      %{
        rating_score: D.from_float(smoothed_score) |> D.round(2),
        rating_count: rating_count,
        rating_weighted_sum: D.from_float(weighted_sum) |> D.round(6),
        rating_weight_total: D.from_float(weighted_total) |> D.round(6)
      }
    end
  end

  def recency_weight(submitted_at, now) do
    submitted_at = submitted_at || now
    age_seconds = max(DateTime.diff(now, submitted_at, :second), 0)
    age_days = age_seconds / 86_400
    1.0 / (1.0 + age_days * Policy.rating_decay_per_day())
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
