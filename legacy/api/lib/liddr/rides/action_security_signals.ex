defmodule Liddr.Rides.ActionSecuritySignals do
  @moduledoc false

  require Logger

  alias Liddr.Location.Redis
  alias Liddr.Security.Policy

  @supported_actions [
    :ride_request,
    :rider_cancel,
    :driver_cancel,
    :driver_no_show,
    :ride_message_send
  ]

  @defaults %{
    enabled: true,
    ip_window_seconds: 600,
    ip_max_events: 40,
    ip_max_distinct_users: 8,
    device_window_seconds: 600,
    device_max_events: 25,
    device_max_distinct_users: 3,
    enforce_ip_on_enforce_mode: false,
    log_ttl_seconds: 60
  }

  def enforce(action, user_id, request_meta) when action in @supported_actions do
    policy = policy()

    if policy.enabled do
      signals =
        []
        |> maybe_collect_ip_signal(action, user_id, request_meta, policy)
        |> maybe_collect_device_signal(action, user_id, request_meta, policy)

      maybe_block_or_observe(action, user_id, signals, policy)
    else
      :ok
    end
  end

  def enforce(_action, _user_id, _request_meta), do: :ok

  defp maybe_collect_ip_signal(signals, action, user_id, request_meta, policy) do
    case evaluate_ip_signal(action, user_id, request_meta, policy) do
      {:flag, signal} -> [signal | signals]
      :ok -> signals
    end
  end

  defp maybe_collect_device_signal(signals, action, user_id, request_meta, policy) do
    case evaluate_device_signal(action, user_id, request_meta, policy) do
      {:flag, signal} -> [signal | signals]
      :ok -> signals
    end
  end

  defp evaluate_ip_signal(action, user_id, request_meta, policy) do
    with ip when is_binary(ip) <- normalize_text(meta_value(request_meta, :ip)),
         {:ok, %{count: count, distinct_users: distinct_users}} <-
           update_counters(action, :ip, ip, user_id, policy.ip_window_seconds, policy),
         true <- count >= policy.ip_max_events and distinct_users >= policy.ip_max_distinct_users do
      {:flag, %{type: :ip_hotspot, count: count, distinct_users: distinct_users}}
    else
      _ -> :ok
    end
  end

  defp evaluate_device_signal(action, user_id, request_meta, policy) do
    with device when is_binary(device) <- normalize_text(meta_value(request_meta, :device)),
         {:ok, %{count: count, distinct_users: distinct_users}} <-
           update_counters(action, :device, device, user_id, policy.device_window_seconds, policy),
         true <-
           count >= policy.device_max_events or
             distinct_users >= policy.device_max_distinct_users do
      {:flag, %{type: :device_abuse, count: count, distinct_users: distinct_users}}
    else
      _ -> :ok
    end
  end

  defp update_counters(action, dimension, raw_value, user_id, window_seconds, policy) do
    base_key = base_key(action, dimension, raw_value)
    count_key = base_key <> ":count"
    users_key = base_key <> ":users"
    ttl = Integer.to_string(window_seconds)
    user_id_value = Integer.to_string(user_id)

    commands = [
      ["INCR", count_key],
      ["EXPIRE", count_key, ttl],
      ["SADD", users_key, user_id_value],
      ["EXPIRE", users_key, ttl],
      ["SCARD", users_key]
    ]

    redis_module = policy.redis_module

    case redis_module.pipeline(commands) do
      {:ok, [count, _expire_count, _sadd, _expire_users, distinct_users]} ->
        with {:ok, count_value} <- parse_counter(count),
             {:ok, distinct_users_value} <- parse_counter(distinct_users) do
          {:ok, %{count: count_value, distinct_users: distinct_users_value}}
        else
          _ -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp maybe_block_or_observe(_action, _user_id, [], _policy), do: :ok

  defp maybe_block_or_observe(action, user_id, signals, policy) do
    mode = Policy.security_mode()

    maybe_log_signal(action, user_id, mode, signals, policy)

    if mode == :enforce and blocking_signal?(signals, policy) do
      {:error, :ride_action_secondary_rate_limited}
    else
      :ok
    end
  end

  defp blocking_signal?(signals, policy) do
    Enum.any?(signals, fn signal ->
      case signal.type do
        :device_abuse -> true
        :ip_hotspot -> policy.enforce_ip_on_enforce_mode
      end
    end)
  end

  defp signal_payload(signal) do
    %{
      type: signal.type,
      count: signal.count,
      distinct_users: signal.distinct_users
    }
  end

  defp maybe_log_signal(action, user_id, mode, signals, policy) do
    case claim_log_slot(action, signals, policy) do
      :log ->
        Logger.warning("[ride.security_signal] abnormal action pattern detected",
          action: action,
          user_id: user_id,
          mode: mode,
          signals: Enum.map(signals, &signal_payload/1)
        )

      :skip ->
        :ok
    end
  end

  defp claim_log_slot(action, signals, policy) do
    ttl = Integer.to_string(policy.log_ttl_seconds)
    key = log_key(action, signals)

    case policy.redis_module.pipeline([["INCR", key], ["EXPIRE", key, ttl]]) do
      {:ok, [1, _expire]} -> :log
      {:ok, [_count, _expire]} -> :skip
      _ -> :log
    end
  end

  defp log_key(action, signals) do
    types =
      signals
      |> Enum.map(& &1.type)
      |> Enum.sort()
      |> Enum.map_join(",", &to_string/1)

    "ride:security:v1:log:#{action}:#{types}"
  end

  defp base_key(action, dimension, raw_value) do
    fingerprint =
      raw_value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 22)

    "ride:security:v1:#{action}:#{dimension}:#{fingerprint}"
  end

  defp parse_counter(value) when is_integer(value), do: {:ok, value}

  defp parse_counter(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_counter(_value), do: :error

  defp meta_value(meta, key) when is_map(meta),
    do: Map.get(meta, key) || Map.get(meta, Atom.to_string(key))

  defp meta_value(_meta, _key), do: nil

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp policy do
    configured = Application.get_env(:liddr, __MODULE__, [])

    %{
      enabled: resolve_bool(configured, :enabled),
      ip_window_seconds: resolve_int(configured, :ip_window_seconds, 30, 86_400),
      ip_max_events: resolve_int(configured, :ip_max_events, 1, 10_000),
      ip_max_distinct_users: resolve_int(configured, :ip_max_distinct_users, 1, 1_000),
      device_window_seconds: resolve_int(configured, :device_window_seconds, 30, 86_400),
      device_max_events: resolve_int(configured, :device_max_events, 1, 10_000),
      device_max_distinct_users: resolve_int(configured, :device_max_distinct_users, 1, 1_000),
      log_ttl_seconds: resolve_int(configured, :log_ttl_seconds, 5, 86_400),
      enforce_ip_on_enforce_mode: resolve_bool(configured, :enforce_ip_on_enforce_mode),
      redis_module: Keyword.get(configured, :redis_module, Redis)
    }
  end

  defp resolve_int(configured, key, min, max) do
    default = Map.fetch!(@defaults, key)

    parsed =
      case Keyword.get(configured, key, default) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int_or_nil(value)
        _ -> nil
      end

    value = if is_integer(parsed), do: parsed, else: default
    if value < min or value > max, do: default, else: value
  end

  defp resolve_bool(configured, key) do
    default = Map.fetch!(@defaults, key)

    case Keyword.get(configured, key, default) do
      value when value in [true, "true", "1", "yes", "on"] -> true
      value when value in [false, "false", "0", "no", "off"] -> false
      _ -> default
    end
  end

  defp parse_int_or_nil(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
