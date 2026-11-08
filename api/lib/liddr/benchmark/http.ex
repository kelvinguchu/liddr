defmodule Liddr.Benchmark.Http do
  @moduledoc false

  alias Liddr.Benchmark.HttpFixtures
  alias Liddr.Rides.ActionRateLimiter

  def run(opts) do
    config = build_config(opts)
    IO.puts("Preparing benchmark state...")
    state = HttpFixtures.prepare_state(config)
    {:ok, finch_pid} = start_benchmark_finch(config)
    IO.puts("Running benchmarks against #{config.base_url}")

    previous_limits = Application.get_env(:liddr, ActionRateLimiter)

    try do
      Application.put_env(:liddr, ActionRateLimiter, ride_request_max_requests: 100_000)

      Enum.map(scenarios(config), fn scenario ->
        benchmark_scenario(config, state, scenario)
      end)
      |> print_report(config)
    after
      stop_benchmark_finch(finch_pid)
      restore_env(ActionRateLimiter, previous_limits)
      IO.puts("Cleaning up benchmark state...")
      HttpFixtures.cleanup_state(state)
    end
  end

  defp build_config(opts) do
    concurrency = max(Keyword.get(opts, :concurrency, 16), 1)
    total = max(Keyword.get(opts, :requests, 200), 1)
    request_total = max(Keyword.get(opts, :request_total, min(total, 100)), 1)
    mixed_total = max(Keyword.get(opts, :mixed_total, total), 1)
    scenario = normalize_scenario(Keyword.get(opts, :scenario))

    %{
      base_url: Keyword.get(opts, :base_url, "http://127.0.0.1:4000"),
      scenario: scenario,
      concurrency: concurrency,
      total: total,
      warmup: max(Keyword.get(opts, :warmup, min(div(total, 10), 20)), 0),
      request_total: request_total,
      mixed_total: mixed_total,
      rider_pool_size: max(max(concurrency * 4, 32), request_total),
      driver_pool_size: max(concurrency * 2, 16),
      finch_name: Liddr.BenchmarkFinch
    }
  end

  defp scenarios(config) do
    all = [
      %{name: "health", total: config.total, runner: &request_health/2},
      %{name: "driver_location", total: config.total, runner: &request_driver_location/2},
      %{name: "ride_request", total: config.request_total, runner: &request_ride_request/2},
      %{name: "mixed_live", total: config.mixed_total, runner: &request_mixed_live/2}
    ]

    case config.scenario do
      nil -> all
      scenario -> Enum.filter(all, &(&1.name == scenario))
    end
  end

  defp benchmark_scenario(config, state, scenario) do
    IO.puts(
      "  -> #{scenario.name}: warmup #{config.warmup}, requests #{scenario.total}, concurrency #{config.concurrency}"
    )

    execute_requests(config, state, scenario.runner, config.warmup)
    result = execute_requests(config, state, scenario.runner, scenario.total)
    Map.put(result, :name, scenario.name)
  end

  defp execute_requests(_config, _state, _runner, 0),
    do: %{latencies_ms: [], status_counts: %{}, errors: 0, throughput: 0.0, operations: %{}}

  defp execute_requests(config, state, runner, total) do
    started_at = System.monotonic_time()

    results =
      1..total
      |> Task.async_stream(fn index -> run_request(index, config, state, runner) end,
        max_concurrency: config.concurrency,
        ordered: false,
        timeout: 60_000
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          %{latency_ms: 0.0, status: :task_exit, ok?: false, error: inspect(reason)}
      end)

    elapsed_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    %{
      latencies_ms: results |> Enum.filter(& &1.ok?) |> Enum.map(& &1.latency_ms) |> Enum.sort(),
      status_counts: Enum.frequencies_by(results, & &1.status),
      errors: Enum.count(results, &(not &1.ok?)),
      throughput: total / max(elapsed_ms / 1000.0, 0.001),
      operations: operation_breakdown(results)
    }
  end

  defp run_request(index, config, state, runner) do
    start_native = System.monotonic_time()
    result = runner.(index, {config, state})
    latency_ms = duration_ms(start_native, System.monotonic_time())
    Map.put(result, :latency_ms, latency_ms)
  end

  defp request_health(_index, {config, _state}) do
    perform_request(config.base_url, :get, "/api/health", [], nil)
    |> Map.put(:operation, :health)
  end

  defp request_driver_location(index, {config, state}) do
    driver = Enum.at(state.drivers, rem(index - 1, length(state.drivers)))
    offset = rem(index, 20) * 0.00005

    perform_request(
      config.base_url,
      :post,
      "/api/drivers/me/location",
      auth_headers(driver.access_token),
      %{"lat" => driver.lat + offset, "lng" => driver.lng + offset, "speed_kmh" => 28}
    )
  end

  defp request_ride_request(index, {config, state}) do
    rider = Enum.at(state.riders, rem(index - 1, length(state.riders)))

    headers =
      auth_headers(rider.access_token) ++
        [
          {"idempotency-key", "bench-ride-request-#{index}"},
          {"x-device-id", "bench-device-#{index}"}
        ]

    perform_request(config.base_url, :post, "/api/rides/requests", headers, %{
      "vehicle_category_id" => state.category.id,
      "quote_id" => rider.quote_id,
      "offer_limit" => 1,
      "offer_ttl_seconds" => 30
    })
    |> Map.put(:operation, :ride_request)
  end

  defp request_mixed_live(index, {config, state}) do
    case rem(index - 1, 20) do
      bucket when bucket < 14 ->
        request_driver_location(index, {config, state}) |> Map.put(:operation, :driver_location)

      bucket when bucket < 18 ->
        request_driver_offers(index, {config, state}) |> Map.put(:operation, :driver_offers)

      _bucket ->
        request_ride_request(index, {config, state})
    end
  end

  defp request_driver_offers(index, {config, state}) do
    driver = Enum.at(state.drivers, rem(index - 1, length(state.drivers)))

    perform_request(
      config.base_url,
      :get,
      "/api/rides/offers",
      auth_headers(driver.access_token),
      nil
    )
    |> Map.put(:operation, :driver_offers)
  end

  defp perform_request(base_url, method, path, headers, json) do
    case Req.request(
           method: method,
           url: base_url <> path,
           headers: headers,
           json: json,
           finch: Liddr.BenchmarkFinch,
           receive_timeout: 60_000,
           pool_timeout: 60_000
         ) do
      {:ok, %Req.Response{status: status}} -> %{status: status, ok?: status in [200, 201]}
      {:error, error} -> %{status: :transport_error, ok?: false, error: inspect(error)}
    end
  end

  defp start_benchmark_finch(config) do
    Finch.start_link(
      name: config.finch_name,
      pools: %{default: [size: max(config.concurrency * 2, 64), count: 1]}
    )
  end

  defp stop_benchmark_finch(pid) when is_pid(pid) do
    Process.unlink(pid)
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  defp auth_headers(access_token), do: [{"authorization", "Bearer #{access_token}"}]

  defp print_report(results, config) do
    IO.puts("")
    IO.puts("Benchmark report")
    IO.puts("base_url=#{config.base_url} concurrency=#{config.concurrency}")

    Enum.each(results, fn result ->
      IO.puts(
        "#{result.name}: throughput=#{Float.round(result.throughput, 2)} req/s errors=#{result.errors} statuses=#{inspect(result.status_counts)}"
      )

      IO.puts(
        "  p50=#{metric(result.latencies_ms, 50)}ms p95=#{metric(result.latencies_ms, 95)}ms p99=#{metric(result.latencies_ms, 99)}ms max=#{metric(result.latencies_ms, 100)}ms"
      )

      print_operation_breakdown(result.operations)
    end)
  end

  defp metric([], _percentile), do: "n/a"

  defp metric(latencies_ms, percentile),
    do: latencies_ms |> percentile(percentile) |> Float.round(2)

  defp percentile(latencies_ms, 100), do: List.last(latencies_ms)

  defp percentile(latencies_ms, percentile),
    do:
      Enum.at(
        latencies_ms,
        min(max(ceil(length(latencies_ms) * percentile / 100) - 1, 0), length(latencies_ms) - 1)
      )

  defp duration_ms(start_native, stop_native),
    do: System.convert_time_unit(stop_native - start_native, :native, :microsecond) / 1000.0

  defp operation_breakdown(results) do
    results
    |> Enum.group_by(&Map.get(&1, :operation, :unknown))
    |> Map.new(fn {operation, entries} ->
      latencies =
        entries
        |> Enum.filter(& &1.ok?)
        |> Enum.map(& &1.latency_ms)
        |> Enum.sort()

      {operation,
       %{
         count: length(entries),
         errors: Enum.count(entries, &(not &1.ok?)),
         p50: metric(latencies, 50),
         p95: metric(latencies, 95),
         p99: metric(latencies, 99)
       }}
    end)
  end

  defp print_operation_breakdown(operations) when map_size(operations) <= 1, do: :ok

  defp print_operation_breakdown(operations) do
    operations
    |> Enum.sort_by(fn {operation, _stats} -> Atom.to_string(operation) end)
    |> Enum.each(fn {operation, stats} ->
      IO.puts(
        "  #{operation}: count=#{stats.count} errors=#{stats.errors} p50=#{stats.p50}ms p95=#{stats.p95}ms p99=#{stats.p99}ms"
      )
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_env(key, value), do: Application.put_env(:liddr, key, value)

  defp normalize_scenario(nil), do: nil

  defp normalize_scenario(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      scenario -> scenario
    end
  end

  defp normalize_scenario(_value), do: nil
end
