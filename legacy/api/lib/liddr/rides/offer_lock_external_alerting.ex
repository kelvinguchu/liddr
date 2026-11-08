defmodule Liddr.Rides.OfferLockExternalAlerting do
  @moduledoc false

  require Logger

  @valid_levels ~w(warning critical)
  @valid_providers ~w(raw slack pagerduty_events_v2)
  @pagerduty_events_url "https://events.pagerduty.com/v2/enqueue"
  @source "liddr.offer_lock_monitor"

  def notify(health_payload, opts \\ [])

  def notify(%{} = health_payload, opts) do
    config = resolved_config(opts)
    recommendation = normalize_recommendation(Map.get(health_payload, :alert_recommendation, %{}))

    if config.enabled and notify_level?(recommendation.level, config.min_level) do
      with {:ok, request} <- build_request(config, health_payload, recommendation) do
        maybe_emit_test(config, request.body)
        dispatch_webhook(request, config.test_pid)
      end
    else
      :ok
    end
  end

  def notify(_health_payload, _opts), do: :ok

  defp build_request(config, health_payload, recommendation) do
    base_payload = build_raw_payload(health_payload, recommendation)
    headers = build_headers(config.auth_header)

    case config.provider do
      "slack" ->
        {:ok,
         %{
           provider: "slack",
           url: config.webhook_url,
           headers: headers,
           timeout_ms: config.timeout_ms,
           body: build_slack_payload(base_payload, config)
         }}

      "pagerduty_events_v2" ->
        case config.pagerduty_routing_key do
          nil ->
            {:error, :missing_pagerduty_routing_key}

          routing_key ->
            {:ok,
             %{
               provider: "pagerduty_events_v2",
               url: config.webhook_url || @pagerduty_events_url,
               headers: headers,
               timeout_ms: config.timeout_ms,
               body: build_pagerduty_payload(base_payload, routing_key)
             }}
        end

      _ ->
        {:ok,
         %{
           provider: "raw",
           url: config.webhook_url,
           headers: headers,
           timeout_ms: config.timeout_ms,
           body: base_payload
         }}
    end
  end

  defp dispatch_webhook(_request, test_pid) when is_pid(test_pid), do: :ok
  defp dispatch_webhook(%{url: ""}, _test_pid), do: {:error, :missing_webhook_url}
  defp dispatch_webhook(%{url: nil}, _test_pid), do: {:error, :missing_webhook_url}

  defp dispatch_webhook(request, _test_pid) do
    case Req.post(request.url,
           json: request.body,
           headers: request.headers,
           receive_timeout: request.timeout_ms
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: response_body}} ->
        Logger.error(
          "[rides.offer_lock.external_alert] provider=#{request.provider} webhook_failed status=#{status} body=#{inspect(response_body)}"
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error(
          "[rides.offer_lock.external_alert] provider=#{request.provider} webhook_transport_error=#{inspect(reason)}"
        )

        {:error, {:transport_error, reason}}
    end
  end

  defp build_headers(nil), do: [{"content-type", "application/json"}]
  defp build_headers(""), do: [{"content-type", "application/json"}]

  defp build_headers(auth_header) do
    [{"content-type", "application/json"}, {"authorization", auth_header}]
  end

  defp build_raw_payload(health_payload, recommendation) do
    %{
      "source" => @source,
      "timestamp" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "level" => recommendation.level,
      "code" => recommendation.code,
      "message" => recommendation.message,
      "dispatch_blocking_risk" => Map.get(health_payload, :dispatch_blocking_risk, %{}),
      "current_window" => Map.get(health_payload, :current_window, %{}),
      "last_window" => Map.get(health_payload, :last_window, %{})
    }
  end

  defp build_slack_payload(base_payload, config) do
    level = String.upcase(base_payload["level"] || "UNKNOWN")
    code = base_payload["code"] || "UNKNOWN"
    message = base_payload["message"] || "Offer lock alert"
    mode = get_value(base_payload["dispatch_blocking_risk"], :mode, "unknown")
    blocked = get_value(base_payload["dispatch_blocking_risk"], :current_window_blocked, 0)

    text = "[Liddr][#{level}] #{code}: #{message}"

    %{
      "text" => text,
      "blocks" => [
        %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}},
        %{
          "type" => "section",
          "fields" => [
            %{"type" => "mrkdwn", "text" => "*Mode*\n#{mode}"},
            %{"type" => "mrkdwn", "text" => "*Current blocked*\n#{blocked}"}
          ]
        }
      ]
    }
    |> maybe_put("channel", config.slack_channel)
    |> maybe_put("username", config.slack_username)
  end

  defp build_pagerduty_payload(base_payload, routing_key) do
    %{
      "routing_key" => routing_key,
      "event_action" => "trigger",
      "dedup_key" => dedup_key(base_payload),
      "payload" => %{
        "summary" => pagerduty_summary(base_payload),
        "source" => @source,
        "severity" => pagerduty_severity(base_payload["level"]),
        "timestamp" => base_payload["timestamp"],
        "custom_details" => base_payload
      }
    }
  end

  defp pagerduty_summary(base_payload) do
    "[Liddr][#{String.upcase(base_payload["level"] || "UNKNOWN")}] #{base_payload["code"]}: #{base_payload["message"]}"
  end

  defp dedup_key(base_payload) do
    mode = get_value(base_payload["dispatch_blocking_risk"], :mode, "unknown")
    code = base_payload["code"] || "UNKNOWN"
    "liddr-offer-lock-#{code}-#{mode}"
  end

  defp pagerduty_severity("critical"), do: "critical"
  defp pagerduty_severity("warning"), do: "warning"
  defp pagerduty_severity(_unknown), do: "error"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get_value(map, atom_key, default) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, Atom.to_string(atom_key)) || default
  end

  defp get_value(_map, _atom_key, default), do: default

  defp maybe_emit_test(%{test_pid: test_pid}, payload) when is_pid(test_pid) do
    send(test_pid, {:offer_lock_external_alert, payload})
  end

  defp maybe_emit_test(_config, _payload), do: :ok

  defp normalize_recommendation(%{} = recommendation) do
    %{
      level:
        to_string(Map.get(recommendation, :level) || Map.get(recommendation, "level") || "ok"),
      code: Map.get(recommendation, :code) || Map.get(recommendation, "code"),
      message: Map.get(recommendation, :message) || Map.get(recommendation, "message")
    }
  end

  defp notify_level?(level, min_level) do
    rank(level) >= rank(min_level) and level in @valid_levels
  end

  defp rank("critical"), do: 2
  defp rank("warning"), do: 1
  defp rank(_unknown), do: 0

  defp resolved_config(opts) do
    app_config = Application.get_env(:liddr, __MODULE__, [])
    merged = Keyword.merge(app_config, opts)

    %{
      enabled: Keyword.get(merged, :enabled, false),
      provider: normalize_provider(Keyword.get(merged, :provider, "raw")),
      webhook_url: normalize_text(Keyword.get(merged, :webhook_url)),
      min_level: normalize_level(Keyword.get(merged, :min_level, "critical")),
      timeout_ms: Keyword.get(merged, :timeout_ms, 3_000),
      auth_header: normalize_text(Keyword.get(merged, :auth_header)),
      pagerduty_routing_key: normalize_text(Keyword.get(merged, :pagerduty_routing_key)),
      slack_channel: normalize_text(Keyword.get(merged, :slack_channel)),
      slack_username: normalize_text(Keyword.get(merged, :slack_username)),
      test_pid: Keyword.get(merged, :test_pid)
    }
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp normalize_level(value) when is_binary(value) do
    level = String.downcase(String.trim(value))
    if level in @valid_levels, do: level, else: "critical"
  end

  defp normalize_level(_value), do: "critical"

  defp normalize_provider(value) when is_binary(value) do
    provider = String.downcase(String.trim(value))
    if provider in @valid_providers, do: provider, else: "raw"
  end

  defp normalize_provider(_value), do: "raw"
end
