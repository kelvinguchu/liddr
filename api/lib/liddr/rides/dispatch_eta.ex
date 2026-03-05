defmodule Liddr.Rides.DispatchEta do
  @moduledoc false

  alias Liddr.Rides.CategoryRouting

  @defaults %{
    enabled: true,
    probe_limit: 8,
    max_concurrency: 4,
    timeout_ms: 1_200,
    fallback_speed_kph: 28.0,
    min_eta_seconds: 30,
    max_eta_seconds: 7_200
  }

  def annotate(candidates, pickup, category_slug, now, limit, opts \\ [])

  def annotate(candidates, pickup, category_slug, now, limit, opts)
      when is_list(candidates) and is_map(pickup) and is_binary(category_slug) and
             is_integer(limit) and limit > 0 and is_struct(now, DateTime) do
    config = policy()
    fallback_all = fallback_for_all(candidates, config)

    if config.enabled and candidates != [] do
      probe_limit = resolve_probe_limit(limit, opts, config)

      candidates
      |> Enum.sort_by(&eta_sort_distance/1, :asc)
      |> do_annotate_with_routes(pickup, category_slug, now, probe_limit, config)
    else
      fallback_all
    end
  end

  def annotate(candidates, _pickup, _category_slug, _now, _limit, _opts)
      when is_list(candidates) do
    fallback_for_all(candidates, policy())
  end

  defp do_annotate_with_routes(candidates, pickup, category_slug, now, probe_limit, config) do
    {probe, remainder} = Enum.split(candidates, probe_limit)
    eta_index = route_eta_index(probe, pickup, category_slug, now, config)

    Enum.map(probe ++ remainder, fn candidate ->
      case Map.get(eta_index, candidate.driver_id) do
        {eta_seconds, source} when is_integer(eta_seconds) and eta_seconds > 0 ->
          Map.merge(candidate, %{eta_seconds: eta_seconds, eta_source: source})

        _ ->
          fallback_eta(candidate, config)
      end
    end)
  end

  defp route_eta_index(candidates, pickup, category_slug, now, config) do
    routing = CategoryRouting.for_category(category_slug, now)
    max_concurrency = min(config.max_concurrency, max(length(candidates), 1))

    candidates
    |> Task.async_stream(
      fn candidate ->
        {candidate.driver_id, route_eta(candidate, pickup, routing, config)}
      end,
      ordered: false,
      max_concurrency: max_concurrency,
      timeout: config.timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {driver_id, {:ok, eta_seconds, source}}}, acc ->
        Map.put(acc, driver_id, {eta_seconds, source})

      _result, acc ->
        acc
    end)
  end

  defp route_eta(candidate, pickup, routing, config) do
    input = %{
      origin: %{lat: candidate.lat, lng: candidate.lng},
      destination: %{lat: pickup.lat, lng: pickup.lng},
      travel_mode: routing.travel_mode,
      routing_preference: routing.routing_preference,
      departure_time: routing.departure_time
    }

    case routes_client().compute_route(input) do
      {:ok, %{duration_s: duration_s}} when is_integer(duration_s) and duration_s > 0 ->
        {:ok, clamp(duration_s, config), "google_routes"}

      _ ->
        {:error, :eta_unavailable}
    end
  end

  defp fallback_for_all(candidates, config), do: Enum.map(candidates, &fallback_eta(&1, config))

  defp fallback_eta(candidate, config) do
    Map.merge(candidate, %{
      eta_seconds: fallback_eta_seconds(candidate.distance_m, config),
      eta_source: "haversine_fallback"
    })
  end

  defp fallback_eta_seconds(distance_m, config) do
    speed_mps = config.fallback_speed_kph * 1000.0 / 3600.0
    seconds = trunc(Float.ceil(max(distance_m, 0.0) / max(speed_mps, 1.0)))
    clamp(seconds, config)
  end

  defp clamp(value, config) when is_integer(value) do
    value
    |> max(config.min_eta_seconds)
    |> min(config.max_eta_seconds)
  end

  defp eta_sort_distance(%{distance_m: distance_m}) when is_number(distance_m), do: distance_m
  defp eta_sort_distance(_candidate), do: 9_999_999.0

  defp resolve_probe_limit(limit, opts, config) do
    override = Keyword.get(opts, :dispatch_eta_probe_limit)
    requested = if is_integer(override) and override > 0, do: override, else: limit * 3
    max(limit, min(requested, config.probe_limit))
  end

  defp policy do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      enabled: get_bool(config, :enabled, @defaults.enabled),
      probe_limit: get_int(config, :probe_limit, @defaults.probe_limit),
      max_concurrency: get_int(config, :max_concurrency, @defaults.max_concurrency),
      timeout_ms: get_int(config, :timeout_ms, @defaults.timeout_ms),
      fallback_speed_kph: get_float(config, :fallback_speed_kph, @defaults.fallback_speed_kph),
      min_eta_seconds: get_int(config, :min_eta_seconds, @defaults.min_eta_seconds),
      max_eta_seconds: get_int(config, :max_eta_seconds, @defaults.max_eta_seconds)
    }
  end

  defp get_bool(config, key, default) do
    case Keyword.get(config, key, default) do
      value when value in [true, false] -> value
      _ -> default
    end
  end

  defp get_int(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp get_float(config, key, default) do
    case Keyword.get(config, key, default) do
      value when is_integer(value) and value > 0 -> value * 1.0
      value when is_float(value) and value > 0.0 -> value
      _ -> default
    end
  end

  defp routes_client,
    do: Application.get_env(:liddr, :google_routes_client, Liddr.Maps.RoutesClient)
end
