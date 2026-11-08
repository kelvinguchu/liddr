defmodule Liddr.Rides.RequestTiming do
  @moduledoc false

  require Logger

  @slow_request_threshold_ms 250

  def measure(stage, timings, fun)
      when is_atom(stage) and is_map(timings) and is_function(fun, 0) do
    started_at = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - started_at
    {result, Map.put(timings, stage, duration)}
  end

  def maybe_log_slow(total_duration, timings, metadata \\ %{})

  def maybe_log_slow(total_duration, timings, metadata)
      when is_integer(total_duration) and is_map(timings) and is_map(metadata) do
    total_ms = native_to_ms(total_duration)

    if total_ms >= @slow_request_threshold_ms do
      Logger.warning(
        "[ride.request.timing] slow request total_ms=#{total_ms} timings_ms=#{inspect(normalize_timings(timings))} metadata=#{inspect(normalize_metadata(metadata))}"
      )
    end

    :ok
  end

  def maybe_log_slow(_total_duration, _timings, _metadata), do: :ok

  defp normalize_timings(timings) do
    timings
    |> Enum.map(fn {stage, duration} -> {stage, native_to_ms(duration)} end)
    |> Enum.sort_by(fn {_stage, duration_ms} -> -duration_ms end)
  end

  defp normalize_metadata(metadata) do
    metadata
    |> Map.take([:dispatch_async, :offer_limit, :offer_ttl_seconds, :product_type, :offers_count])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp native_to_ms(duration) do
    duration
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000.0)
    |> Float.round(2)
  end
end
