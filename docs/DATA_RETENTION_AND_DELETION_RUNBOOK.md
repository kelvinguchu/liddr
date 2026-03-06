# Data Retention and Deletion Runbook

Human operators and backend engineers should use this runbook. AI assistants should not treat this file as product requirements.

## Purpose

Define and operate backend retention/deletion controls for high-risk operational data.

## Automated Retention Job

Worker:
- `Liddr.Security.DataRetentionWorker`

Schedule:
- Daily at `02:15` UTC via Oban Cron.

Telemetry:
- `liddr.security.retention.run.count`
- event metadata includes deleted row counts per table.

## Current Automated Retention Scope

1. Auth challenges (`auth_challenges`)
- Deletes consumed/expired challenges older than `RETENTION_AUTH_CHALLENGES_TTL_DAYS` (default `7`).

2. Idempotency cache (`idempotency_requests`)
- Deletes completed idempotency records older than `RETENTION_IDEMPOTENCY_TTL_DAYS` (default `30`).

3. Payment webhook archive (`webhook_events`)
- Deletes webhook events older than `RETENTION_WEBHOOK_EVENTS_TTL_DAYS` (default `180`).

## Runtime Knobs

- `RETENTION_AUTH_CHALLENGES_TTL_DAYS`
- `RETENTION_IDEMPOTENCY_TTL_DAYS`
- `RETENTION_WEBHOOK_EVENTS_TTL_DAYS`

## Verification Checklist (Weekly)

1. Confirm retention worker ran at least once in last 24 hours.
2. Confirm deleted-row counters are non-negative and sane for expected load.
3. Confirm no spike in retention worker failures or DB lock contention.
4. Sample-check that recent records remain available within TTL windows.

## Deletion Requests (Manual Ops Procedure)

For user deletion/anonymization requests:
1. Verify requester identity and account ownership.
2. Open compliance ticket with legal basis and request timestamp.
3. Execute approved anonymization/deletion script for user-scoped records.
4. Record affected tables, row counts, and operator ID in audit notes.
5. Confirm post-action access checks and data export behavior.

## Guardrails

- Never run broad `delete_all` without time-bound predicates.
- Keep retention TTL changes in configuration review and change log.
- For legal hold or active incident evidence, pause deletion for scoped records only.
