defmodule Liddr.Rides.OfferLockMonitor do
  @moduledoc false

  use GenServer

  require Logger

  @telemetry_event_acquire [:liddr, :rides, :offer_lock, :acquire]
  @telemetry_event_blocked [:liddr, :rides, :offer_lock, :blocked]
  @default_window_ms 60_000
  @default_min_attempts 20
  @default_unavailable_ratio_alert_threshold 0.05

  alias Liddr.Rides.OfferLockExternalAlerting
  alias Liddr.Rides.OfferLockMonitorHealth

  def start_link(opts \\ []) do
    config = resolved_config(opts)

    if config.enabled do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      :ignore
    end
  end

  def health do
    config = resolved_config([])

    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(pid, :health, 5_000)

      _ ->
        {:ok,
         OfferLockMonitorHealth.build_payload(config, false, %{}, %{}, default_last_window(), nil)}
    end
  end

  @impl true
  def init(config) do
    handler_ids = attach_telemetry_handlers!()

    {:ok,
     %{
       config: config,
       handler_ids: handler_ids,
       timer_ref: schedule_flush(config.window_ms),
       stats_by_source: %{},
       blocked_by_source: %{},
       last_window: default_last_window(),
       last_alert: nil
     }}
  end

  def handle_acquire_event(_event_name, measurements, metadata, monitor_pid) do
    send(monitor_pid, {:offer_lock_acquire_event, measurements, metadata})
  end

  def handle_blocked_event(_event_name, measurements, metadata, monitor_pid) do
    send(monitor_pid, {:offer_lock_blocked_event, measurements, metadata})
  end

  @impl true
  def handle_call(:health, _from, state) do
    payload =
      health_payload(
        state.config,
        true,
        state.stats_by_source,
        state.blocked_by_source,
        state.last_window,
        state.last_alert
      )

    {:reply, {:ok, payload}, state}
  end

  @impl true
  def handle_info({:offer_lock_acquire_event, measurements, metadata}, state) do
    count = parse_count(Map.get(measurements, :count))
    source = normalize_source(Map.get(metadata, :source))
    result = normalize_result(Map.get(metadata, :result))

    next_stats_by_source =
      Map.update(
        state.stats_by_source,
        source,
        stats_for(count, result),
        &merge_stats(&1, count, result)
      )

    {:noreply, %{state | stats_by_source: next_stats_by_source}}
  end

  def handle_info({:offer_lock_blocked_event, measurements, metadata}, state) do
    count = parse_count(Map.get(measurements, :count))
    source = normalize_source(Map.get(metadata, :source))

    next_blocked_by_source =
      Map.update(state.blocked_by_source, source, count, fn current -> current + count end)

    {:noreply, %{state | blocked_by_source: next_blocked_by_source}}
  end

  def handle_info(:flush_window, state) do
    alerts =
      state.stats_by_source
      |> Enum.map(fn {source, stats} ->
        evaluate_source(state.config, source, stats)
      end)
      |> Enum.reject(&is_nil/1)

    health_snapshot =
      health_payload(
        state.config,
        true,
        state.stats_by_source,
        state.blocked_by_source,
        state.last_window,
        state.last_alert
      )

    maybe_notify_external_alert(health_snapshot)
    maybe_emit_test_window(state.config, state.stats_by_source, state.blocked_by_source, alerts)

    next_last_alert =
      case alerts do
        [] -> state.last_alert
        _ -> List.last(alerts)
      end

    {:noreply,
     %{
       state
       | stats_by_source: %{},
         blocked_by_source: %{},
         last_window: %{
           closed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
           stats_by_source: state.stats_by_source,
           blocked_by_source: state.blocked_by_source,
           alerts: alerts
         },
         last_alert: next_last_alert,
         timer_ref: schedule_flush(state.config.window_ms)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
    :ok
  end

  defp evaluate_source(config, source, stats) do
    unavailable_ratio = unavailable_ratio(stats)

    if stats.attempts >= config.min_attempts and
         unavailable_ratio >= config.unavailable_ratio_alert_threshold do
      alert = %{
        source: source,
        attempts: stats.attempts,
        unavailable: stats.unavailable,
        unavailable_ratio: unavailable_ratio,
        threshold: config.unavailable_ratio_alert_threshold
      }

      Logger.warning(
        "[rides.offer_lock.alert] source=#{alert.source} attempts=#{alert.attempts} unavailable=#{alert.unavailable} unavailable_ratio=#{Float.round(alert.unavailable_ratio, 4)} threshold=#{Float.round(alert.threshold, 4)}"
      )

      maybe_emit_test_alert(config, alert)
      alert
    else
      nil
    end
  end

  defp schedule_flush(window_ms), do: Process.send_after(self(), :flush_window, window_ms)

  defp attach_telemetry_handlers! do
    acquire_handler_id = handler_id("acquire")
    blocked_handler_id = handler_id("blocked")

    :ok =
      :telemetry.attach(
        acquire_handler_id,
        @telemetry_event_acquire,
        &__MODULE__.handle_acquire_event/4,
        self()
      )

    :ok =
      :telemetry.attach(
        blocked_handler_id,
        @telemetry_event_blocked,
        &__MODULE__.handle_blocked_event/4,
        self()
      )

    [acquire_handler_id, blocked_handler_id]
  end

  defp handler_id(suffix) do
    "liddr-offer-lock-monitor-#{suffix}-#{System.system_time(:microsecond)}-#{:erlang.unique_integer([:positive])}"
  end

  defp resolved_config(opts) do
    app_config = Application.get_env(:liddr, __MODULE__, [])
    merged = Keyword.merge(app_config, opts)

    %{
      enabled: Keyword.get(merged, :enabled, true),
      window_ms: Keyword.get(merged, :window_ms, @default_window_ms),
      min_attempts: Keyword.get(merged, :min_attempts, @default_min_attempts),
      unavailable_ratio_alert_threshold:
        Keyword.get(
          merged,
          :unavailable_ratio_alert_threshold,
          @default_unavailable_ratio_alert_threshold
        ),
      test_pid: Keyword.get(merged, :test_pid)
    }
  end

  defp stats_for(count, "unavailable"), do: %{attempts: count, unavailable: count}
  defp stats_for(count, _result), do: %{attempts: count, unavailable: 0}

  defp merge_stats(current, count, "unavailable") do
    %{attempts: current.attempts + count, unavailable: current.unavailable + count}
  end

  defp merge_stats(current, count, _result) do
    %{attempts: current.attempts + count, unavailable: current.unavailable}
  end

  defp unavailable_ratio(%{attempts: attempts, unavailable: unavailable}) when attempts > 0 do
    unavailable / attempts
  end

  defp unavailable_ratio(_stats), do: 0.0

  defp normalize_source(source) when is_binary(source) do
    case String.trim(source) do
      "" -> "unknown"
      value -> value
    end
  end

  defp normalize_source(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source(_source), do: "unknown"

  defp normalize_result(result) when is_atom(result), do: Atom.to_string(result)
  defp normalize_result(result) when is_binary(result), do: String.trim(result)
  defp normalize_result(_result), do: "unknown"

  defp parse_count(value) when is_integer(value) and value > 0, do: value
  defp parse_count(_value), do: 1

  defp maybe_emit_test_alert(%{test_pid: test_pid}, alert) when is_pid(test_pid) do
    send(test_pid, {:offer_lock_monitor_alert, alert})
  end

  defp maybe_emit_test_alert(_config, _alert), do: :ok

  defp maybe_emit_test_window(%{test_pid: test_pid}, stats_by_source, blocked_by_source, alerts)
       when is_pid(test_pid) do
    send(test_pid, {:offer_lock_monitor_window, stats_by_source, blocked_by_source, alerts})
  end

  defp maybe_emit_test_window(_config, _stats_by_source, _blocked_by_source, _alerts), do: :ok

  defp maybe_notify_external_alert(health_snapshot) do
    case OfferLockExternalAlerting.notify(health_snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[rides.offer_lock.external_alert] notify_failed=#{inspect(reason)}")
    end
  end

  defp default_last_window do
    OfferLockMonitorHealth.default_last_window()
  end

  defp health_payload(
         config,
         monitor_running,
         current_stats,
         current_blocked,
         last_window,
         last_alert
       ) do
    OfferLockMonitorHealth.build_payload(
      config,
      monitor_running,
      current_stats,
      current_blocked,
      last_window,
      last_alert
    )
  end
end
