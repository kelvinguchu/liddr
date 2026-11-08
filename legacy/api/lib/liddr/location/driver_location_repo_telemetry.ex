defmodule Liddr.Location.DriverLocationRepoTelemetry do
  @moduledoc false

  use GenServer

  @handler_id "liddr-location-driver-repo-query"
  @process_key {__MODULE__, :summary}
  @event [:liddr, :repo, :query]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def track(fun) when is_function(fun, 0) do
    previous = Process.get(@process_key)
    Process.put(@process_key, empty_summary())

    try do
      result = fun.()
      {result, Process.get(@process_key, empty_summary())}
    after
      restore_previous(previous)
    end
  end

  def emit_summary(summary) when is_map(summary) do
    :telemetry.execute(
      [:liddr, :location, :driver_update, :db],
      %{
        total_time: Map.get(summary, :total_time, 0),
        queue_time: Map.get(summary, :queue_time, 0),
        query_time: Map.get(summary, :query_time, 0),
        decode_time: Map.get(summary, :decode_time, 0),
        query_count: Map.get(summary, :query_count, 0)
      },
      %{}
    )
  end

  def normalize(summary) when is_map(summary) do
    %{
      query_count: Map.get(summary, :query_count, 0),
      total_time_ms: native_to_ms(Map.get(summary, :total_time, 0)),
      queue_time_ms: native_to_ms(Map.get(summary, :queue_time, 0)),
      query_time_ms: native_to_ms(Map.get(summary, :query_time, 0)),
      decode_time_ms: native_to_ms(Map.get(summary, :decode_time, 0))
    }
  end

  @impl true
  def init(:ok) do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> {:ok, %{}}
      {:error, :already_exists} -> {:ok, %{}}
    end
  end

  def handle_event(_event, measurements, _metadata, _config) do
    case Process.get(@process_key) do
      nil ->
        :ok

      summary ->
        Process.put(
          @process_key,
          %{
            query_count: summary.query_count + 1,
            total_time: summary.total_time + Map.get(measurements, :total_time, 0),
            queue_time: summary.queue_time + Map.get(measurements, :queue_time, 0),
            query_time: summary.query_time + Map.get(measurements, :query_time, 0),
            decode_time: summary.decode_time + Map.get(measurements, :decode_time, 0)
          }
        )
    end
  end

  defp restore_previous(nil), do: Process.delete(@process_key)
  defp restore_previous(previous), do: Process.put(@process_key, previous)

  defp empty_summary do
    %{query_count: 0, total_time: 0, queue_time: 0, query_time: 0, decode_time: 0}
  end

  defp native_to_ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000.0)
    |> Float.round(2)
  end
end
