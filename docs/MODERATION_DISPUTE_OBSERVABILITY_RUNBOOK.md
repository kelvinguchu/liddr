# Moderation and Dispute Observability Runbook

Human operators and backend engineers should use this runbook. AI assistants should not treat this file as product requirements.

## Purpose

Track moderation/dispute pressure and react quickly when:
- moderation triage/review actions are being 429 rate-limited
- moderation/dispute processing throughput falls behind pending workload

## Telemetry Signals

- `liddr.moderation.report.triage.rate_limited.count`
- `liddr.moderation.report.review.rate_limited.count`
- `liddr.moderation.report.triage.success.count`
- `liddr.moderation.report.review.success.count`
- `liddr.disputes.create.success.count`
- `liddr.disputes.resolve.success.count`
- `liddr.observability.moderation.alert.count` (`code`, `level` tags)

Alert telemetry event emitted by monitor:
- `[:liddr, :observability, :moderation, :alert]`
  - metadata:
    - `code`:
      - `REPORT_TRIAGE_RATE_LIMITED_SPIKE`
      - `REPORT_REVIEW_RATE_LIMITED_SPIKE`
      - `MODERATION_DISPUTE_THROUGHPUT_LOW`
    - `level` (`warning`)

## Runtime Knobs

- `MODERATION_MONITOR_ENABLED`
- `MODERATION_MONITOR_WINDOW_MS`
- `MODERATION_TRIAGE_RATE_LIMITED_ALERT_COUNT`
- `MODERATION_REVIEW_RATE_LIMITED_ALERT_COUNT`
- `MODERATION_THROUGHPUT_MIN_PER_WINDOW`
- `MODERATION_PENDING_REPORTS_ALERT_THRESHOLD`

## Default Policy

- Window: `60s`
- Triage 429 alert threshold: `5`
- Review 429 alert threshold: `5`
- Throughput-low alert:
  - pending open reports >= `25`
  - total moderation/dispute success actions in window < `1`

## Operational Response

1. `REPORT_TRIAGE_RATE_LIMITED_SPIKE` or `REPORT_REVIEW_RATE_LIMITED_SPIKE`
- Check current ops staffing versus queue pressure.
- Confirm limiter settings are intentional (`REPORT_TRIAGE_MAX_REQUESTS`, `REPORT_REVIEW_MAX_REQUESTS`).
- If abuse attack is suspected, keep limits strict and temporarily increase manual reviewer capacity.

2. `MODERATION_DISPUTE_THROUGHPUT_LOW`
- Inspect open reports/disputes backlog and reviewer activity.
- Verify DB latency and API error rates on moderation/dispute endpoints.
- Check for downstream blockers (idempotency, enforcement transactions, notification backlog).

3. Escalation
- If alerts persist for `>= 3` consecutive windows, page on-call and incident owner.
- Document incident timeline and mitigation decisions in ops channel.

## Dashboard Minimums

- 429 triage/review counters by minute.
- moderation/dispute throughput counters by minute.
- open report backlog trend.
- p95 latency for:
  - `PATCH /api/moderation/reports/:id/triage`
  - `POST /api/moderation/reports/:id/reviews`
  - `POST /api/disputes`
  - `POST /api/ops/disputes/:id/resolve`
