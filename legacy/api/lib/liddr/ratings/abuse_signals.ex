defmodule Liddr.Ratings.AbuseSignals do
  import Ecto.Query

  alias Liddr.Ratings.Rating
  alias Liddr.Ratings.SignalReports
  alias Liddr.Repo

  @category_slug "rating_manipulation_risk"
  @fallback_category_slug "fraud_or_scam"
  @default_fallback_category_slug "other"

  @five_star_velocity_window_hours 1
  @five_star_velocity_threshold 10

  @pair_window_days 30
  @pair_min_count 5
  @pair_min_ratio 0.7

  def maybe_emit_abuse_signals(rating, now) do
    rated_user_id = rating.rated_user_id
    rated_by_user_id = rating.rated_by_user_id

    if rating.score == 5 and rating.include_in_score and is_nil(rating.nullified_at) do
      emit_five_star_velocity_signal(rated_user_id, now)
      emit_pair_concentration_signal(rated_user_id, rated_by_user_id, now)
    else
      :ok
    end

    {:ok, :processed}
  end

  defp emit_five_star_velocity_signal(rated_user_id, now) do
    cutoff = DateTime.add(now, -@five_star_velocity_window_hours * 3600, :second)

    count =
      Repo.one(
        from r in Rating,
          where:
            r.rated_user_id == ^rated_user_id and r.score == 5 and r.include_in_score == true and
              is_nil(r.nullified_at) and r.submitted_at >= ^cutoff,
          select: count(r.id)
      ) || 0

    if count >= @five_star_velocity_threshold do
      _ =
        SignalReports.create_system_report(%{
          now: now,
          reported_user_id: rated_user_id,
          category_candidates: [
            @category_slug,
            @fallback_category_slug,
            @default_fallback_category_slug
          ],
          cooldown_days: 3,
          context_reference: "rating_abuse:five_star_velocity_1h:#{rated_user_id}",
          severity_level: 3,
          incident_type: "fraud",
          description:
            "Potential rating manipulation: #{count} five-star ratings in the last #{@five_star_velocity_window_hours} hour(s).",
          metadata: %{
            "rating_abuse_signal_code" => "five_star_velocity_1h",
            "five_star_count" => count,
            "window_hours" => @five_star_velocity_window_hours
          }
        })

      :ok
    else
      :ok
    end
  end

  defp emit_pair_concentration_signal(rated_user_id, rated_by_user_id, now) do
    cutoff = DateTime.add(now, -@pair_window_days * 86_400, :second)

    pair_count =
      Repo.one(
        from r in Rating,
          where:
            r.rated_user_id == ^rated_user_id and r.rated_by_user_id == ^rated_by_user_id and
              r.score == 5 and r.include_in_score == true and is_nil(r.nullified_at) and
              r.submitted_at >= ^cutoff,
          select: count(r.id)
      ) || 0

    total_count =
      Repo.one(
        from r in Rating,
          where:
            r.rated_user_id == ^rated_user_id and r.include_in_score == true and
              is_nil(r.nullified_at) and r.submitted_at >= ^cutoff,
          select: count(r.id)
      ) || 0

    pair_ratio =
      if total_count > 0 do
        pair_count / total_count
      else
        0.0
      end

    if pair_count >= @pair_min_count and total_count >= @pair_min_count and
         pair_ratio >= @pair_min_ratio do
      _ =
        SignalReports.create_system_report(%{
          now: now,
          reported_user_id: rated_user_id,
          category_candidates: [
            @category_slug,
            @fallback_category_slug,
            @default_fallback_category_slug
          ],
          cooldown_days: 7,
          context_reference:
            "rating_abuse:pair_concentration_30d:#{rated_user_id}:#{rated_by_user_id}",
          severity_level: 3,
          incident_type: "fraud",
          description:
            "Potential rating collusion: rater #{rated_by_user_id} contributed #{pair_count}/#{total_count} five-star ratings in #{@pair_window_days} days.",
          metadata: %{
            "rating_abuse_signal_code" => "pair_concentration_30d",
            "rated_by_user_id" => rated_by_user_id,
            "pair_count" => pair_count,
            "total_count" => total_count,
            "pair_ratio" => pair_ratio,
            "window_days" => @pair_window_days
          }
        })

      :ok
    else
      :ok
    end
  end
end
