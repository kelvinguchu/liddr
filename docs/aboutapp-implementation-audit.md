# aboutapp.md Implementation Audit

Last audited: 2026-03-05  
Source reviewed: `docs/aboutapp.md`

## Legend
- `done`: implemented in current API backend
- `partial`: implemented in part, or implemented with intentional drift from `aboutapp.md`
- `missing`: not implemented in current repository

## Section-by-section status

| Section | Status | Notes | Primary evidence |
|---|---|---|---|
| 1. Product Overview | done | Multi-category rides/send, subscription-first model, category pricing all present. | `api/priv/repo/migrations/*core_domain*`, `api/lib/liddr/rides/vehicle_category.ex` |
| 2. Technology Stack | partial | Elixir/Phoenix/Postgres/Redis/Oban/M-Pesa/Google Maps present. Mobile apps and some stack specifics are not implemented in this repo. Geo indexing is now handled directly by the S2 location engine. | `api/mix.exs`, `api/config/config.exs`, `api/lib/liddr/location/s2.ex` |
| 3. High-Level Architecture | partial | Modular monolith boundaries are present, but not an Elixir umbrella split as written. | `api/lib/liddr/rides.ex`, `api/lib/liddr/auth.ex`, `api/lib/liddr/verification.ex` |
| 4. Data Flow: Full Ride Lifecycle | partial | End-to-end request->dispatch->execution->completion exists. Drift: request path is HTTP, and completion does not auto-run STK by default. | `api/lib/liddr_web/router.ex`, `api/lib/liddr/rides/execution/completion.ex` |
| 5. Geographic Indexing (S2) | done | Spatial indexing now uses the S2 location engine directly for driver supply lookup, canonical hex location tokens, and official `RegionCoverer`-based radius covering. | `api/lib/liddr/location/s2.ex`, `api/lib/liddr/location/s2_hilbert.ex`, `api/lib/liddr/location/s2_native.ex`, `api/native/s2cover/main.go`, `api/lib/liddr/location/supply_index.ex` |
| 6. Real-Time Location Architecture | partial | Redis-backed supply and live updates are present; driver location ingestion is HTTP endpoint (`/drivers/me/location`) rather than socket write path as documented. | `api/lib/liddr_web/controllers/driver_location_controller.ex`, `api/lib/liddr/location/supply_index.ex` |
| 7. Dispatch Engine (DISCO) | done | Multi-wave offer dispatch, ETA-aware candidate scoring, offer TTL, expiry, and race controls are implemented. | `api/lib/liddr/rides/dispatch_worker.ex`, `api/lib/liddr/rides/candidate_selection.ex`, `api/lib/liddr/rides/driver_offer_lock.ex` |
| 8. Dynamic Pricing Engine | done | Distance/time + category logic + market multipliers + discounting + rounding are implemented. | `api/lib/liddr/rides/pricing.ex`, `api/lib/liddr/rides/market_multiplier.ex`, `api/lib/liddr/rides/route_pricing.ex` |
| 9. Database Design | partial | Core tables and category-aware schema exist, but table shapes/names differ from document prose (expected in iterative implementation). | `api/priv/repo/migrations` |
| 10. Subscription Management | done | Weekly subscription lifecycle, payments, webhooks, reconciliation, and ops lookup are implemented. | `api/lib/liddr/subscriptions/payments.ex`, `api/lib/liddr/subscriptions/reconciliation.ex`, `api/lib/liddr_web/controllers/subscription_controller.ex` |
| 11. Notification Architecture | partial | WebSocket + push token flows are implemented. SMS for broad ride lifecycle fallback is not currently wired as described. | `api/lib/liddr/rides/realtime.ex`, `api/lib/liddr/rides/push_client/fcm.ex`, `api/lib/liddr/auth/otp_delivery/host_pinnacle.ex` |
| 12. Send (Package Delivery) | partial | Send quote/request/proofs and recipient confirmation-in-app implemented. Drift: no public token endpoint shape exactly matching doc text. | `api/lib/liddr_web/controllers/send_controller.ex`, `api/lib/liddr_web/controllers/send_delivery_controller.ex`, `api/lib/liddr_web/router.ex` |
| 13. Women Only Category | done | Rider eligibility + candidate filtering + category enforcement implemented. | `api/lib/liddr/rides/women_only.ex`, `api/lib/liddr/rides/candidate_selection.ex` |
| 14. Category-Aware Dispatch Engine | done | Dispatch filtering by category and women-only constraints is implemented. | `api/lib/liddr/rides/candidate_selection.ex`, `api/lib/liddr/rides/dispatch_worker.ex` |
| 15. Scalability Plan | partial | Foundations exist (Oban workers, Redis supply index, modular domains). Multi-region/fleet-scale infra strategy is not codified in repo config. | `api/config/config.exs`, `docker-compose.yml` |
| 16. Resilience and Failure Handling | partial | Reconciliation/watchdogs/offer-lock monitoring present; full regional failover/read-only replica strategy remains infra/ops work. | `api/lib/liddr/subscriptions/reconciliation_worker.ex`, `api/lib/liddr/rides/pickup_watchdog_worker.ex`, `api/lib/liddr/rides/offer_lock_monitor.ex` |
| 17. Security | partial | JWT auth, role checks, OTP challenge rate limiting, mandatory TOTP enrollment on `ops/admin` routes, TOTP-preferred session-bound step-up auth on high-risk ops mutations, callback token/IP gating, stricter M-Pesa response validation, response/log redaction for sensitive ops/payment surfaces, and fail-closed GCS object-key + metadata verification for verification uploads are implemented. Full signature-based webhook validation, encrypted-at-rest handling for the most sensitive fields, and some infra controls remain open. | `api/lib/liddr/auth/crypto.ex`, `api/lib/liddr/auth/step_up.ex`, `api/lib/liddr/auth/totp.ex`, `api/lib/liddr/auth/totp_enrollment.ex`, `api/lib/liddr/security/redaction.ex`, `api/lib/liddr/payments/mpesa/client.ex`, `api/lib/liddr/payments/mpesa/sanitizer.ex`, `api/lib/liddr/storage/gcs.ex`, `api/lib/liddr/storage/gcs/object_metadata.ex`, `api/lib/liddr_web/plugs/require_totp_enrollment.ex`, `api/lib/liddr_web/plugs/require_step_up_auth.ex`, `api/lib/liddr_web/plugs/enforce_ip_allowlist.ex`, `api/lib/liddr/auth/challenge_rate_limiter.ex` |
| 18. Driver Verification and KYC | partial | Verification applications/docs/OCR/malware/human review pipeline exists, and document submission now verifies driver-scoped storage keys plus actual GCS object metadata before acceptance. Some policy-level legal/third-party verification choices in doc are not exactly mirrored. | `api/lib/liddr/verification/*.ex`, `api/lib/liddr/storage/gcs/object_metadata.ex`, `api/lib/liddr_web/controllers/verification_ops_controller.ex` |
| 19. MVP - What To Build First | partial | Most backend P0 capabilities are implemented; mobile/admin full product surfaces are not in this repo yet. | `api/lib/liddr_web/router.ex`, `api/lib/liddr/rides/*`, `api/lib/liddr/subscriptions/*` |
| 20. Ride State Machine | done | Enforced ride states/transitions, event trail, and controller guards are implemented. | `api/lib/liddr/rides/ride.ex`, `api/lib/liddr/rides/execution/*`, `api/lib/liddr/rides/events.ex` |
| 21. Cancellation and No-Show Policy | done | Rider/driver cancellations, no-show gating, integrity classification, enforcement actions, and notifications are implemented. | `api/lib/liddr/rides/execution/cancellation.ex`, `api/lib/liddr/rides/integrity/*` |
| 22. Dispute Resolution System | done | End-to-end dispute flow is implemented: in-app dispute submission, ops resolution outcomes, compensation creation for refund outcomes, and ops compensation processing (paid/cancelled) with audit metadata. | `api/lib/liddr/disputes/*`, `api/lib/liddr_web/controllers/dispute_controller.ex`, `api/lib/liddr_web/controllers/dispute_ops_controller.ex` |
| 23. Data Privacy and Regulatory Compliance | done | Added automated retention/deletion worker with configurable TTLs plus operator runbook for retention/deletion handling and manual compliance requests. | `api/lib/liddr/security/data_retention.ex`, `api/lib/liddr/security/data_retention_worker.ex`, `docs/DATA_RETENTION_AND_DELETION_RUNBOOK.md` |
| 24. Observability and Monitoring | done | Added moderation/dispute telemetry counters, alert monitor for 429 spikes/throughput drops, and production runbook for operations response. | `api/lib/liddr/observability/moderation_events.ex`, `api/lib/liddr/observability/moderation_monitor.ex`, `api/lib/liddr_web/telemetry.ex`, `docs/MODERATION_DISPUTE_OBSERVABILITY_RUNBOOK.md` |
| 25. Rate Limiting and Abuse Prevention | partial | Auth challenge rate limiting, ride action rate/security limits, and moderation/dispute endpoint limits (report create, report triage, report review, dispute create, ride-message report, ops dispute resolve) are implemented; full endpoint-by-endpoint quotas from doc are not fully implemented yet. | `api/lib/liddr/auth/challenge_rate_limiter.ex`, `api/lib/liddr/rides/action_rate_limiter.ex`, `api/lib/liddr/rides/action_security_signals.ex`, `api/lib/liddr/moderation/action_rate_limiter.ex` |
| 26. Ratings System | done | Two-way rating actions, weighted/decayed scoring, nullification, abuse/enforcement signals, and ops controls are implemented. | `api/lib/liddr/ratings/*`, `api/lib/liddr_web/controllers/rating_controller.ex`, `api/lib/liddr_web/controllers/rating_ops_controller.ex` |
| 27. API Contract | partial | Canonical route contract is now auto-generated from router (`docs/API_CONTRACT.md`) with drift test coverage; remaining gap is richer OpenAPI schemas/examples per endpoint. | `api/lib/liddr_web/router.ex`, `api/lib/liddr_web/api_contract.ex`, `api/test/liddr_web/api_contract_test.exs`, `docs/API_CONTRACT.md` |
| 28. Development Environment | partial | Actual repo now uses Docker-first env and `.env` runtime patterns; document still describes older local-only setup in places. | `docker-compose.yml`, `api/.env.example`, `api/config/runtime.exs` |
| 29. Git Workflow | done | CI workflow now enforces production docs hardening guard (`MIX_ENV=prod`) in pull requests and main pushes. | `.github/workflows/api-prod-security-guard.yml`, `api/lib/mix/tasks/liddr.security.prod_guard.ex` |

## Overall

- Backend implementation coverage for `aboutapp.md` is strong on core product domains: auth, rides, dispatch, pricing, subscriptions, verification, moderation, ratings, and shared rides.
- Main remaining gaps are:
  - architecture/document drift (transport details, modular-monolith vs umbrella wording),
  - operations/compliance depth,
  - some API contract differences,
  - repo workflow/tooling surfaces (CI workflows, cross-platform apps/admin in same repo).

## Recommended next docs update

Update `docs/aboutapp.md` to reflect current implementation reality before adding new features:
- align transport details and architecture wording to current implementation,
- align API routes/examples to `router.ex`,
- mark infra/compliance/mobile/admin sections as roadmap vs current state.
