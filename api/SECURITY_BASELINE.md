# Liddr Security Baseline and Implementation Plan

Last updated: March 3, 2026
Owner: API Platform Team
Status: Active baseline (must be followed before broad feature expansion)

## Why This Exists
Liddr handles high-risk data: driver identity documents, location history, account enforcement decisions, and payment records. This document defines the minimum security and privacy posture required before scaling product features.

## Industry Pattern (Uber/Bolt-Informed)
Public Uber/Bolt safety/privacy materials indicate a defense-in-depth model:
- identity verification and ongoing checks
- strict access controls
- encryption in transit and at rest
- privacy masking/data minimization
- fraud/abuse monitoring with human review

This document adapts that pattern to Liddr.

## Security Objectives
1. Prevent unauthorized access to driver/rider sensitive data.
2. Prevent account takeover and identity abuse.
3. Protect verification media and payment flows.
4. Keep high-risk operations fully auditable.
5. Detect and respond to fraud/abuse quickly.

## Data Classification
### Critical
- National ID, Driver License, PSV details, Good Conduct certificate
- Verification media (images, scans, metadata)
- Payment identifiers and webhook payloads

### Sensitive
- Phone numbers, exact pickup/dropoff points, live location
- Report narratives and evidence

### Operational
- Category config, non-sensitive analytics, generic app telemetry

## Mandatory Controls
### 1) Authentication and Session Security
- Short-lived access tokens, rotating refresh tokens
- Refresh token reuse detection and family revocation
- Rate limiting for challenge/OTP endpoints
- Mandatory MFA for `ops` and `admin`
- Step-up authentication for high-risk actions (suspend/ban/override)

### 2) Authorization (Least Privilege)
- Role-based authorization on every protected route
- High-risk moderation actions restricted to `ops/admin`
- Explicit denial by default for unscoped actions
- Role grant/revoke actions must be auditable

### 3) Verification Document Security
- Private object storage only (no public bucket access)
- Signed URLs with short TTL for controlled access
- Upload validation: file type, size, content checks
- Malware scanning for uploaded media
- Immutable checksum tracking and review trail
- EXIF stripping on served copies to minimize leakage

### 4) Encryption and Key Management
- TLS for all client and service communication
- Encryption at rest for DB/storage
- Field-level encryption for highly sensitive columns
- KMS-backed key management and key rotation policy

### 5) Privacy by Design
- Phone masking for rider-driver communications
- Minimize sensitive fields in logs/responses
- Clear retention and deletion policy for documents/evidence
- Purpose-bound access to personal data

### 6) Abuse/Fraud Detection
- Signals for account sharing, suspicious device change, repeated failures
- Risk scoring + escalation path to human ops review
- Velocity controls for reporting/auth attempts/sensitive endpoints

### 7) Monitoring, Audit, and Incident Response
- Structured audit logs for:
  - auth/session events
  - verification review actions
  - moderation/enforcement actions
  - payment state transitions/webhooks
- Alerting on high-risk anomalies
- Incident runbook and recovery procedure

### 8) Secure SDLC
- Dependency scanning in CI
- Container image scanning in CI
- Secret scanning and secret rotation policy
- Security review checklist for high-risk PRs

## Implementation Order (Do Not Reorder)
1. Threat model + data flow map + classification signoff
2. MFA + step-up auth for privileged/sensitive actions
3. Verification upload pipeline hardening (scan/validate/audit)
4. Field-level encryption rollout for critical fields
5. Fraud/risk scoring and security monitoring dashboards
6. Retention/deletion automation and compliance checks

## Definition of Done for Security Phase 1
- All protected routes enforce both authentication and role checks.
- Ops/admin high-risk actions require step-up auth.
- Verification documents stored privately with signed access.
- Audit trail exists for auth, moderation, verification, payments.
- CI includes dependency + container + secret scans.

## Team Rules
- No secrets in code or git history.
- No bypass route for role enforcement.
- No direct DB access from app code without auditable service path.
- No new sensitive data field without classification and retention decision.

## Development Access Controls (Human Operators Only)
Human operators only: this section is for manual developer operations in dev/staging.
AI agents should ignore this section when generating runtime/security enforcement logic.

- Rotating residential ISP IPs are not reliable for strict static allowlists in active development.
- In development, prefer layered controls:
  - mandatory callback/register tokens in headers
  - short-lived signed webhook/session secrets
  - optional temporary CIDR allowlist entries (time-boxed and removed quickly)
- Use tunnel/static-edge options for stable ingress when possible:
  - Cloudflare Tunnel / Cloudflare Access service token
  - static egress IP from a small VPS/NAT gateway used by the dev team
- Keep strict IP allowlists mandatory in production, but allow `observe` mode in dev while tokens are enforced.
- Rotate dev callback/register tokens regularly and immediately after sharing logs/screenshots.
- Never rely on query-string tokens as the only control for production; prefer header transport.

## Google Maps Platform Rollout Checklist (Human Operators Only)
Human operators only: this section is for manual cloud/project setup by developers and operators.
AI agents should ignore this section when generating runtime/security enforcement logic.

After enabling required Google Maps APIs and obtaining `GOOGLE_MAPS_API_KEY`, complete all items below before production rollout.

1. Billing and budget controls
- Confirm billing account is active on the target GCP project.
- Configure daily and monthly budget alerts to avoid silent cost spikes.

2. Key restrictions (mandatory)
- Never leave keys unrestricted.
- Backend/server key:
  - restrict by API list (`Routes`, `Places`, `Geocoding`, `Roads`)
  - restrict by server egress IPs in production
- Mobile keys:
  - Android key restricted by package name + SHA fingerprint
  - iOS key restricted by bundle identifier

3. Separate keys by surface
- Use distinct keys; do not share one key across all clients/services.
- Recommended env naming:
  - `GOOGLE_MAPS_API_KEY_SERVER`
  - `GOOGLE_MAPS_API_KEY_ANDROID`
  - `GOOGLE_MAPS_API_KEY_IOS`

4. Quota guardrails
- Configure per-API quota caps, especially for `Routes` and `Places`.
- Configure alerts for quota exhaustion and abnormal 4xx/5xx patterns.

5. Request hygiene requirements
- `Places Autocomplete` must always use session tokens.
- Use field masks on `Routes`/`Places` responses to reduce cost and latency.

6. Secret handling
- Store all keys in environment/secret manager only.
- Never commit keys in code, tests, logs, screenshots, or docs.

### Dev-Environment Note (Rotating ISP IPs)
- Rotating residential ISP IPs are not suitable for stable server-IP restrictions during active local development.
- In dev/staging, use layered controls:
  - token/header-based access controls
  - short-lived secrets
  - optional temporary CIDR allowlist entries
- Keep strict server-IP key restrictions mandatory in production, where egress IPs are stable.

## References (Public Sources)
- Uber Safety: https://www.uber.com/us/en/safety/
- Uber US Safety Report: https://www.uber.com/us/en/about/reports/us-safety-report/
- Uber courier identity update (2025): https://www.uber.com/newsroom/courier-identity-us/
- Uber driver/courier privacy notice (effective Jan 1, 2026): https://www.uber.com/global/en/privacy-notice-drivers-delivery-people/
- Bolt privacy for drivers: https://bolt.eu/en/privacy/privacy-for-drivers/
- Bolt safety team: https://bolt.eu/en/safety-team/
- Bolt information security supplier requirements: https://bolt.eu/en/security/supplier-requirements/
- Bolt public vulnerability policy: https://bolt.eu/en/security/public-vulnerability/
