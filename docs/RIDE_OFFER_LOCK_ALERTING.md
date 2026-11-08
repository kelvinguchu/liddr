# Ride Offer Lock Alerting

Human operators and backend engineers should use this runbook. AI assistants should not treat this file as product requirements.

## Purpose

Detect Redis lock backend degradation early so dispatch does not silently run without offer-lock guarantees.

## Signals

- Telemetry event: `[:liddr, :rides, :offer_lock, :acquire]`
  - Measurements: `count`
  - Metadata: `source`, `result` (`acquired` | `locked` | `unavailable`)
- Telemetry event: `[:liddr, :rides, :offer_lock, :release]`
  - Measurements: `count`
  - Metadata: `source`
- Telemetry event: `[:liddr, :rides, :offer_lock, :blocked]`
  - Emitted when strict mode blocks dispatch due to lock backend unavailability.
  - Measurements: `count`
  - Metadata: `source`
- Runtime warning:
  - `[rides.offer_lock.alert] ...` when unavailable ratio crosses threshold.

## Default Alert Policy

- Window: `60s`
- Minimum attempts before evaluating: `20`
- Alert threshold: `unavailable_ratio >= 0.05` (5%)

## Health Decision Rule

`/api/ops/rides/offer-lock/health` now returns `alert_recommendation` with deterministic actions:

- `critical` (`DISPATCH_BLOCKING_RISK`): strict mode is enabled and current window has blocked or unavailable risk events. Page on-call immediately.
- `warning` (`LOCK_UNAVAILABLE_RATIO_HIGH`): current window ratio crossed threshold with enough attempts. Investigate.
- `ok` (`NONE`): no active lock alert condition.

Health payload includes blocked counters for direct dispatch impact visibility:

- `current_window.totals.blocked`
- `last_window.totals.blocked`
- `dispatch_blocking_risk.current_window_blocked`
- `dispatch_blocking_risk.last_window_blocked`

## Environment Knobs

- `RIDE_OFFER_LOCK_MONITOR_ENABLED`
- `RIDE_OFFER_LOCK_MONITOR_WINDOW_MS`
- `RIDE_OFFER_LOCK_MONITOR_MIN_ATTEMPTS`
- `RIDE_OFFER_LOCK_UNAVAILABLE_RATIO_ALERT_THRESHOLD`
- `RIDE_OFFER_LOCK_EXTERNAL_ALERTS_ENABLED`
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_PROVIDER` (`raw` | `slack` | `pagerduty_events_v2`)
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_WEBHOOK_URL`
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_MIN_LEVEL` (`warning` or `critical`)
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_TIMEOUT_MS`
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_AUTH_HEADER` (optional bearer/header secret)
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_PAGERDUTY_ROUTING_KEY` (required for `pagerduty_events_v2`)
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_SLACK_CHANNEL` (optional)
- `RIDE_OFFER_LOCK_EXTERNAL_ALERT_SLACK_USERNAME` (optional)

## Response Guidance

1. Check Redis container/pod health first (restarts, auth, latency).
2. Verify API can reach Redis over network and credentials are valid.
3. If unresolved, temporarily tighten dispatch ops monitoring because fallback mode allows dispatch without lock guarantees.
4. In strict mode (`RIDE_OFFER_LOCK_ALLOW_UNAVAILABLE_FALLBACK=false`), prioritize `offer_lock.blocked` events as critical dispatch impact.
5. After recovery, confirm alert clears for at least 3 windows and blocked count returns to zero.

## External Webhook Alerts

When `RIDE_OFFER_LOCK_EXTERNAL_ALERTS_ENABLED=true`, the monitor posts alerts using the selected provider.

- Delivery is level-gated by `RIDE_OFFER_LOCK_EXTERNAL_ALERT_MIN_LEVEL` (`warning` or `critical`).
- Optional `Authorization` header can be set via `RIDE_OFFER_LOCK_EXTERNAL_ALERT_AUTH_HEADER`.
- Timeout is controlled by `RIDE_OFFER_LOCK_EXTERNAL_ALERT_TIMEOUT_MS`.
- `raw`: sends full monitor payload to `RIDE_OFFER_LOCK_EXTERNAL_ALERT_WEBHOOK_URL`.
- `slack`: sends Slack-formatted payload (text + blocks) to `RIDE_OFFER_LOCK_EXTERNAL_ALERT_WEBHOOK_URL`.
- `pagerduty_events_v2`: sends PagerDuty Events API v2 payload; defaults URL to `https://events.pagerduty.com/v2/enqueue` when webhook URL is empty.
