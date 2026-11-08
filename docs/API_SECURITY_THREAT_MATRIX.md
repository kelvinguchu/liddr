# API Security Threat Matrix

Last updated: March 6, 2026  
Scope: `api/` backend threat tracking  
Purpose: Convert high-level security concerns into an actionable threat-by-threat worklist.

## How to Use This Document
- Treat this as the working security queue for the API.
- Use it together with:
  - `docs/SECURITY_BASELINE.md`
  - `docs/aboutapp-implementation-audit.md`
- Status meanings:
  - `done`: control exists and is materially enforced
  - `partial`: baseline exists, but coverage or depth is incomplete
  - `missing`: not implemented to a reasonable production standard

## Current Position
- The API is in a strong development state.
- It is not safe to describe it as protected against all threats.
- The biggest remaining risks are ordinary platform risks, not exotic ones:
  - account takeover
  - broken authorization
  - ops misuse
  - webhook/payment abuse
  - verification document leakage
  - bot/business-flow abuse
  - configuration and secret handling mistakes
  - availability pressure on hot paths

## Threat Matrix

| Threat | What it looks like | Current controls | Status | Highest-value next step |
|---|---|---|---|---|
| Account takeover | OTP abuse, stolen sessions, phishing, refresh/session theft | OTP rate limits, session auth, mandatory TOTP enrollment on `ops/admin` surfaces, session-bound step-up for high-risk ops actions, TOTP-preferred step-up when enrolled | partial | Keep TOTP mandatory for `ops/admin` and add passkeys/WebAuthn as the long-term target |
| Broken function-level authorization | User reaches protected admin/ops route they should not access | Route auth, role checks, step-up on high-risk ops mutations | done | Keep route tests and contract drift checks strict |
| Broken object-level authorization | User accesses another user's ride, verification data, payment, or moderation object | Protected route checks exist across core domains | partial | Do a strict object-ownership review for all sensitive read endpoints |
| Privileged ops misuse | Ops/admin resolves payments, suspends users, or reviews documents without sufficient friction | Role checks, audit trail, step-up auth for high-risk mutations | partial | Add stronger MFA and review all privileged read access logging |
| Payment callback fraud | Forged or replayed M-Pesa callback/query/register flows | Callback tokens, reconciliation, idempotent webhook event tracking, callback amount/phone checks, stricter callback URL validation, sanitized stored webhook payloads | partial | Prefer stronger provider trust signals where available and tighten replay validation |
| Payment reconciliation abuse | Mismatched amount/phone/checkout state or delayed callback inconsistencies | Payment state machine, reconciliation worker, negative callback tests, stricter upstream response validation, sanitized query payload persistence | partial | Expand fraud rules around suspicious retries and conflicting callback state |
| Verification document leakage | Public object access, long-lived signed URLs, broad internal access | Private storage, signed access path, malware scanning, review pipeline, scoped storage keys, server-side GCS object metadata verification before document acceptance | partial | Add field-level encryption for critical metadata and verify all access is audited |
| Sensitive data overexposure | Too much personal data in logs, responses, or ops tooling | OTP debug logs now mask identifiers, ops payment payloads return masked identifiers, verification ops responses omit raw storage keys/driver identifiers, ride notification ops payloads are sanitized, retention worker exists | partial | Continue the field-by-field review for identity, payment, and location surfaces, then add encrypted storage for the most sensitive fields |
| Bot and automation abuse | OTP farming, ride request spam, quote scraping, report brigading | Auth/moderation/ride rate limiting, abuse signals, observability alerts | partial | Build a unified risk scoring layer for auth, ride, report, and payment abuse |
| Business-flow abuse | Users exploit valid flows rather than classic bugs | Rate limiting and integrity checks in several domains | partial | Threat-model each sensitive flow: auth, rides, payments, verification, moderation |
| Third-party API trust abuse | Unsafe handling of M-Pesa, Maps, SMS, GCS, OCR responses | Stricter M-Pesa response validation, GCS object-key validation, server-side metadata verification for uploaded documents, and request timeouts exist in key integrations | partial | Continue the boundary audit for Maps, SMS, and OCR paths and fail closed on malformed provider responses |
| Storage/configuration mistakes | Public bucket, overbroad env use, weak key restrictions, bad callback transport | Private storage path, env-based runtime config, prod docs guard, GCS signing limited to validated object keys and driver-scoped prefixes | partial | Complete a production config review for secrets, buckets, keys, and callback settings |
| Secret exposure | Keys or tokens leak into repo, logs, CI, or screenshots | Repo discipline, baseline docs, no-secret rules | partial | Add or tighten CI secret scanning and rotation procedure documentation |
| Dependency or container compromise | Vulnerable package/image lands in runtime | Prod guard exists, but not full security CI posture | partial | Add dependency scan and container image scan in CI |
| Availability attacks | Burst traffic, hot-path exhaustion, queue contention, request floods | Hot-path latency work, telemetry, rate limits, Docker health checks | partial | Continue hot-path protection and add explicit overload/abuse thresholds per endpoint group |
| Realtime/location privacy leakage | Exact location leaks to wrong party or broader internal surface | Authenticated flows, domain boundaries, private backend handling | partial | Review every location read path and minimize exact-coordinate exposure |
| Incident response gap | Breach happens but detection/recovery is slow or unclear | Observability docs and some runbooks exist | partial | Test incident runbooks, alert routing, and backup/restore procedures |
| Audit insufficiency | High-risk actions happen without enough traceability | Audit coverage exists for auth, moderation, verification, payments | partial | Verify every privileged mutation and sensitive read emits operator context |

## Priority Order

### P0
- Keep stronger MFA mandatory for `ops/admin`
- Sensitive data review for logs/responses/storage access
- Third-party trust boundary review for M-Pesa, GCS, Maps, SMS, OCR
- CI secret, dependency, and container scanning

### P1
- Object-level authorization review across sensitive read paths
- Expanded payment fraud/replay controls
- Unified abuse/risk scoring for auth + rides + moderation + payments
- Privileged read auditing

### P2
- Broader incident-response drills
- More mature availability/abuse controls for burst conditions
- Ongoing privacy minimization on realtime and location surfaces

## Work Sequence
1. Keep `ops/admin` authentication stronger than email OTP step-up and plan passkeys/WebAuthn rollout.
2. Perform a sensitive-data exposure pass:
   - logs
   - API responses
   - signed document access
   - payment payload storage
3. Review all third-party integrations as untrusted boundaries.
4. Add CI security automation:
   - secret scan
   - dependency scan
   - container scan
5. Run an object-level authorization audit on sensitive reads.
6. Expand anti-abuse from per-endpoint limits into cross-domain risk scoring.

## Non-Goals
- This document does not promise absolute security.
- This document does not replace code review, threat modeling, or incident drills.
- This document is intentionally focused on realistic API risks, not theoretical edge-case cryptographic attacks.

## External References
- OWASP API Security Top 10 2023: https://owasp.org/API-Security/editions/2023/en/0x11-t10/
- OWASP Automated Threats: https://owasp.org/www-project-automated-threats-to-web-applications/
- NIST SP 800-63B: https://pages.nist.gov/800-63-4/sp800-63b.html
- Google Cloud Storage public access prevention: https://docs.cloud.google.com/storage/docs/public-access-prevention
- Google Cloud Storage signed URLs: https://cloud.google.com/storage/docs/access-control/signed-urls
- Uber safety: https://www.uber.com/us/en/ride/safety/
- Bolt vulnerability policy: https://bolt.eu/en/security/public-vulnerability/
