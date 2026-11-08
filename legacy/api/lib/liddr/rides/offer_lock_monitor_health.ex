defmodule Liddr.Rides.OfferLockMonitorHealth do
  @moduledoc false

  def default_last_window do
    %{
      closed_at: nil,
      stats_by_source: %{},
      blocked_by_source: %{},
      alerts: []
    }
  end

  def build_payload(
        config,
        monitor_running,
        current_stats,
        current_blocked_by_source,
        last_window,
        last_alert
      ) do
    fallback_allow_unavailable =
      Application.get_env(:liddr, :ride_offer_lock_allow_unavailable_fallback, false)

    strict_mode_enabled = not fallback_allow_unavailable
    current_window_payload = window_payload(current_stats, current_blocked_by_source)

    last_window_payload =
      window_payload(last_window.stats_by_source, last_window.blocked_by_source)

    %{
      monitor_enabled: config.enabled,
      monitor_running: monitor_running,
      fallback_allow_unavailable: fallback_allow_unavailable,
      window_ms: config.window_ms,
      min_attempts: config.min_attempts,
      unavailable_ratio_alert_threshold: config.unavailable_ratio_alert_threshold,
      current_window: current_window_payload,
      last_window: %{
        closed_at: last_window.closed_at,
        totals: last_window_payload.totals,
        by_source: last_window_payload.by_source,
        alerts: last_window.alerts
      },
      dispatch_blocking_risk:
        dispatch_blocking_risk_payload(
          strict_mode_enabled,
          current_window_payload.totals,
          last_window_payload.totals
        ),
      alert_recommendation:
        alert_recommendation_payload(
          strict_mode_enabled,
          current_window_payload.totals,
          last_window_payload.totals,
          config.min_attempts,
          config.unavailable_ratio_alert_threshold
        ),
      last_alert: last_alert
    }
  end

  defp dispatch_blocking_risk_payload(strict_mode_enabled, current_totals, last_totals) do
    %{
      mode: if(strict_mode_enabled, do: "strict", else: "fallback"),
      current_window_unavailable: current_totals.unavailable,
      last_window_unavailable: last_totals.unavailable,
      current_window_blocked: current_totals.blocked,
      last_window_blocked: last_totals.blocked,
      current_window_blocking_risk:
        strict_mode_enabled and (current_totals.blocked > 0 or current_totals.unavailable > 0),
      last_window_blocking_risk:
        strict_mode_enabled and (last_totals.blocked > 0 or last_totals.unavailable > 0)
    }
  end

  defp alert_recommendation_payload(
         true,
         %{unavailable: unavailable, blocked: blocked},
         _last_totals,
         _min_attempts,
         _threshold
       )
       when unavailable > 0 or blocked > 0 do
    %{
      level: "critical",
      should_page: true,
      code: "DISPATCH_BLOCKING_RISK",
      message: "Strict mode is enabled and dispatch lock risk events are present."
    }
  end

  defp alert_recommendation_payload(
         _strict_mode_enabled,
         %{attempts: attempts, unavailable_ratio: ratio},
         _last_totals,
         min_attempts,
         threshold
       )
       when attempts >= min_attempts and ratio >= threshold do
    %{
      level: "warning",
      should_page: false,
      code: "LOCK_UNAVAILABLE_RATIO_HIGH",
      message: "Unavailable ratio crossed configured threshold in current window."
    }
  end

  defp alert_recommendation_payload(_strict_mode_enabled, _current_totals, _last_totals, _min, _t) do
    %{
      level: "ok",
      should_page: false,
      code: "NONE",
      message: "No active offer-lock alert condition."
    }
  end

  defp window_payload(stats_by_source, blocked_by_source) do
    %{
      totals: totals_payload(stats_by_source, blocked_by_source),
      by_source: by_source_payload(stats_by_source, blocked_by_source)
    }
  end

  defp totals_payload(stats_by_source, blocked_by_source) do
    totals =
      Enum.reduce(stats_by_source, %{attempts: 0, unavailable: 0}, fn {_source, stats}, acc ->
        %{
          attempts: acc.attempts + stats.attempts,
          unavailable: acc.unavailable + stats.unavailable
        }
      end)

    blocked = Enum.reduce(blocked_by_source, 0, fn {_source, count}, acc -> acc + count end)

    totals
    |> Map.put(:blocked, blocked)
    |> Map.put(:unavailable_ratio, unavailable_ratio(totals))
  end

  defp by_source_payload(stats_by_source, blocked_by_source) do
    all_sources =
      stats_by_source
      |> Map.keys()
      |> Enum.concat(Map.keys(blocked_by_source))
      |> Enum.uniq()

    Enum.into(all_sources, %{}, fn source ->
      stats = Map.get(stats_by_source, source, %{attempts: 0, unavailable: 0})

      {source,
       %{
         attempts: stats.attempts,
         unavailable: stats.unavailable,
         unavailable_ratio: unavailable_ratio(stats),
         blocked: Map.get(blocked_by_source, source, 0)
       }}
    end)
  end

  defp unavailable_ratio(%{attempts: attempts, unavailable: unavailable}) when attempts > 0 do
    unavailable / attempts
  end

  defp unavailable_ratio(_stats), do: 0.0
end
