defmodule Liddr.Observability.ModerationMonitor do
  @moduledoc false

  use GenServer

  import Ecto.Query
  require Logger

  alias Liddr.Moderation.Report
  alias Liddr.Observability.ModerationEvents
  alias Liddr.Repo

  @event_alert [:liddr, :observability, :moderation, :alert]
  @open_statuses ~w(submitted triaged under_review)
  @default_window_ms 60_000
  @default_triage_rate_limited_alert_count 5
  @default_review_rate_limited_alert_count 5
  @default_min_throughput_per_window 1
  @default_pending_reports_alert_threshold 25

  def start_link(opts \\ []) do
    config = resolved_config(opts)

    if config.enabled do
      GenServer.start_link(__MODULE__, config, name: __MODULE__)
    else
      :ignore
    end
  end

  @impl true
  def init(config) do
    {:ok,
     %{
       config: config,
       counts: initial_counts(),
       handler_ids: attach_telemetry_handlers!(),
       timer_ref: schedule_flush(config.window_ms)
     }}
  end

  def handle_event(event_name, measurements, metadata, monitor_pid) do
    send(monitor_pid, {:moderation_telemetry_event, event_name, measurements, metadata})
  end

  @impl true
  def handle_info({:moderation_telemetry_event, event_name, measurements, _metadata}, state) do
    event_count = parse_count(Map.get(measurements, :count))

    next_counts =
      case event_key(event_name) do
        nil -> state.counts
        key -> Map.update(state.counts, key, event_count, &(&1 + event_count))
      end

    {:noreply, %{state | counts: next_counts}}
  end

  def handle_info(:flush_window, state) do
    pending_reports = pending_reports_count()
    throughput = throughput_total(state.counts)
    alerts = build_alerts(state.config, state.counts, pending_reports, throughput)
    emit_alerts(alerts, state.config, state.counts, pending_reports, throughput)
    maybe_emit_test_window(state.config, state.counts, pending_reports, throughput, alerts)

    {:noreply,
     %{
       state
       | counts: initial_counts(),
         timer_ref: schedule_flush(state.config.window_ms)
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
    :ok
  end

  defp schedule_flush(window_ms), do: Process.send_after(self(), :flush_window, window_ms)

  defp event_key([:liddr, :moderation, :report, :triage, :rate_limited]),
    do: :report_triage_rate_limited

  defp event_key([:liddr, :moderation, :report, :review, :rate_limited]),
    do: :report_review_rate_limited

  defp event_key([:liddr, :moderation, :report, :triage, :success]),
    do: :moderation_triage_success

  defp event_key([:liddr, :moderation, :report, :review, :success]),
    do: :moderation_review_success

  defp event_key([:liddr, :disputes, :create, :success]), do: :dispute_create_success
  defp event_key([:liddr, :disputes, :resolve, :success]), do: :dispute_resolve_success
  defp event_key(_event_name), do: nil

  defp parse_count(value) when is_integer(value) and value > 0, do: value
  defp parse_count(_value), do: 1

  defp initial_counts do
    %{
      report_triage_rate_limited: 0,
      report_review_rate_limited: 0,
      moderation_triage_success: 0,
      moderation_review_success: 0,
      dispute_create_success: 0,
      dispute_resolve_success: 0
    }
  end

  defp throughput_total(counts) do
    counts.moderation_triage_success +
      counts.moderation_review_success +
      counts.dispute_create_success +
      counts.dispute_resolve_success
  end

  defp build_alerts(config, counts, pending_reports, throughput) do
    []
    |> maybe_put_alert(
      counts.report_triage_rate_limited >= config.report_triage_rate_limited_alert_count,
      %{code: "REPORT_TRIAGE_RATE_LIMITED_SPIKE", level: "warning"}
    )
    |> maybe_put_alert(
      counts.report_review_rate_limited >= config.report_review_rate_limited_alert_count,
      %{code: "REPORT_REVIEW_RATE_LIMITED_SPIKE", level: "warning"}
    )
    |> maybe_put_alert(
      pending_reports >= config.pending_reports_alert_threshold and
        throughput < config.min_throughput_per_window,
      %{code: "MODERATION_DISPUTE_THROUGHPUT_LOW", level: "warning"}
    )
  end

  defp maybe_put_alert(alerts, true, alert), do: [alert | alerts]
  defp maybe_put_alert(alerts, false, _alert), do: alerts

  defp emit_alerts(alerts, config, counts, pending_reports, throughput) do
    Enum.each(alerts, fn alert ->
      Logger.warning(
        "[moderation.monitor.alert] code=#{alert.code} level=#{alert.level} triage_429=#{counts.report_triage_rate_limited} review_429=#{counts.report_review_rate_limited} throughput=#{throughput} pending_reports=#{pending_reports}"
      )

      :telemetry.execute(@event_alert, %{count: 1}, %{
        code: alert.code,
        level: alert.level
      })

      maybe_emit_test_alert(config, alert)
    end)
  end

  defp pending_reports_count do
    Repo.aggregate(from(r in Report, where: r.status in ^@open_statuses), :count, :id)
  rescue
    _ -> 0
  end

  defp attach_telemetry_handlers! do
    ModerationEvents.event_names()
    |> Enum.with_index()
    |> Enum.map(fn {event, index} ->
      handler_id = handler_id(index)
      :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, self())
      handler_id
    end)
  end

  defp handler_id(index) do
    "liddr-moderation-monitor-#{index}-#{System.system_time(:microsecond)}-#{:erlang.unique_integer([:positive])}"
  end

  defp resolved_config(opts) do
    app_config = Application.get_env(:liddr, __MODULE__, [])
    merged = Keyword.merge(app_config, opts)

    %{
      enabled: Keyword.get(merged, :enabled, true),
      window_ms: Keyword.get(merged, :window_ms, @default_window_ms),
      report_triage_rate_limited_alert_count:
        Keyword.get(
          merged,
          :report_triage_rate_limited_alert_count,
          @default_triage_rate_limited_alert_count
        ),
      report_review_rate_limited_alert_count:
        Keyword.get(
          merged,
          :report_review_rate_limited_alert_count,
          @default_review_rate_limited_alert_count
        ),
      min_throughput_per_window:
        Keyword.get(merged, :min_throughput_per_window, @default_min_throughput_per_window),
      pending_reports_alert_threshold:
        Keyword.get(
          merged,
          :pending_reports_alert_threshold,
          @default_pending_reports_alert_threshold
        ),
      test_pid: Keyword.get(merged, :test_pid)
    }
  end

  defp maybe_emit_test_alert(%{test_pid: test_pid}, alert) when is_pid(test_pid) do
    send(test_pid, {:moderation_monitor_alert, alert})
  end

  defp maybe_emit_test_alert(_config, _alert), do: :ok

  defp maybe_emit_test_window(config, counts, pending_reports, throughput, alerts) do
    case config do
      %{test_pid: test_pid} when is_pid(test_pid) ->
        send(test_pid, {:moderation_monitor_window, counts, pending_reports, throughput, alerts})

      _ ->
        :ok
    end
  end
end
