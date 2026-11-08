defmodule Liddr.Ratings.EnforcementSignals do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.UserRole
  alias Liddr.Ratings.Guardrails
  alias Liddr.Ratings.SignalReports
  alias Liddr.Repo

  @category_slug "rating_quality_risk"
  @fallback_category_slug "other"
  @signal_cooldown_days 7
  @default_role "rider"

  def maybe_emit_low_rating_signal(rated_user_id, stats, now) do
    guardrails = Guardrails.enforcement_snapshot_for_user(rated_user_id, now)
    rating_score = decimal_to_float(stats.rating_score)
    rating_count = parse_non_negative_integer(stats.rating_count, 0)

    cond do
      is_nil(rating_score) ->
        {:ok, :no_rating_score}

      not guardrails.ready? ->
        {:ok, :insufficient_rating_volume}

      true ->
        role = primary_role(rated_user_id)

        case resolve_rule(role, rating_score, rating_count) do
          nil ->
            {:ok, :below_signal_threshold}

          rule ->
            maybe_create_signal_report(rated_user_id, role, rating_score, rating_count, rule, now)
        end
    end
  end

  defp maybe_create_signal_report(rated_user_id, role, rating_score, rating_count, rule, now) do
    SignalReports.create_system_report(%{
      now: now,
      reported_user_id: rated_user_id,
      category_candidates: [@category_slug, @fallback_category_slug],
      cooldown_days: @signal_cooldown_days,
      context_reference: "rating_signal:#{rule.code}:#{rated_user_id}",
      severity_level: rule.severity,
      incident_type: "conduct",
      description: report_description(role, rule, rating_score, rating_count),
      metadata: %{
        "rating_signal_code" => rule.code,
        "rating_role" => role,
        "rating_score" => rating_score,
        "rating_count" => rating_count
      }
    })
  end

  defp resolve_rule("driver", rating_score, rating_count) do
    cond do
      rating_score < 3.0 and rating_count >= 20 ->
        %{code: "driver_critical_3_0_over_20", severity: 5}

      rating_score < 3.5 and rating_count >= 50 ->
        %{code: "driver_low_3_5_over_50", severity: 4}

      rating_score < 3.7 and rating_count >= 30 ->
        %{code: "driver_low_3_7_over_30", severity: 3}

      true ->
        nil
    end
  end

  defp resolve_rule("rider", rating_score, rating_count) do
    if rating_score < 3.5 and rating_count >= 30 do
      %{code: "rider_low_3_5_over_30", severity: 2}
    else
      nil
    end
  end

  defp resolve_rule(_role, _rating_score, _rating_count), do: nil

  defp primary_role(user_id) do
    roles =
      Repo.all(
        from ur in UserRole,
          where: ur.user_id == ^user_id and is_nil(ur.revoked_at),
          select: ur.role
      )

    cond do
      "driver" in roles -> "driver"
      "rider" in roles -> "rider"
      true -> @default_role
    end
  end

  defp report_description(role, rule, rating_score, rating_count) do
    "System signal #{rule.code}: #{role} rating #{rating_score} across #{rating_count} rated rides requires moderation review."
  end

  defp parse_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp parse_non_negative_integer(_value, default), do: default
  defp decimal_to_float(%D{} = value), do: D.to_float(value)
  defp decimal_to_float(value) when is_float(value), do: value
  defp decimal_to_float(value) when is_integer(value), do: value * 1.0
  defp decimal_to_float(_value), do: nil
end
