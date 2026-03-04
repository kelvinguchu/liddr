# Shared Rides Edge Cases (V1 Decisions)

Last updated: March 4, 2026  
Status: Locked for V1 implementation

## Purpose
Define explicit V1 behavior for shared rides so backend, mobile, QA, and ops implement the same rules.

## Scope
- Product type: `shared`
- Market scope for rollout: limited Nairobi S2 zones
- Rider model: rider-initiated pooling (not driver-initiated route publishing)
- Fare model: per-passenger fare (not equal split of one total fare)

## Core V1 Policy
1. Shared ride requests are initiated by riders selecting `product_type=shared`.
2. Driver accepts one pooled assignment context, not separate independent jobs.
3. Pool composition is locked after driver acceptance in V1.
4. Max pool size in V1: 2 riders per shared group.
5. Destination changes are not allowed on shared rides.

## Edge Case Decisions

| Case | V1 decision | Why |
|---|---|---|
| Rider requests shared but no compatible match appears | Fallback to solo offer after wait window, or rider can cancel with no penalty before acceptance | Prevents request dead-end |
| Two riders are compatible but only one driver has seats | Allocate to first accepted feasible group, remaining rider stays in queue | Deterministic allocation |
| Driver receives pooled offer | Offer payload includes full stop sequence + expected earnings | Driver must understand commitment before accept |
| Driver accepts shared offer then asks to drop one rider | Not supported manually in app; only system/ops action for safety incidents | Prevents arbitrary discrimination and disputes |
| Rider cancels before any pickup | Rider removed; remaining rider continues as solo if still feasible | Preserve service for remaining rider |
| Rider cancels after pickup | Rider pays according to in-progress cancellation policy; route re-optimized for remaining rider(s) | Fairness + route continuity |
| Rider no-show at pickup | Start no-show timer per rider; mark rider as no-show when threshold passes; continue for remaining rider(s) | Independent accountability |
| Driver no-show for first pickup | Existing pickup watchdog applies; reassign/cancel by policy | Reuse proven enforcement |
| Driver no-show for second pickup in group | Second rider no-fee cancel rights apply; event logged as shared-specific no-progress signal | Prevents unfair second-rider penalties |
| One rider has cash preference, other has in-app preference | Allowed in V1 only if both payment modes are driver-supported; otherwise match rejected | Prevents collection disputes |
| One rider reports safety incident mid-trip | Remove/terminate affected member by safety policy; incident report required | Safety overrides optimization |
| Driver loses connectivity mid-shared ride | Grace window for reconnect; if expired, trigger recovery path (ops/reassign/cancel) | Data consistency and rider safety |
| Duplicate accept/cancel/start/dropoff requests | Endpoints remain idempotent; first valid transition wins | Race safety |
| Realtime socket miss during trip | Notification persists in `ride_notifications`; clients reconcile via timeline sync | Reliable UX after reconnect |
| One rider rates badly due to co-rider behavior | Reason tags route low rating to non-attributable exclusion where applicable | Prevent unfair rating harm |
| Fraud: same user repeatedly forcing shared cancellations | Integrity counters include shared-specific reasons and thresholds | Abuse control |
| Group state partially written due crash | Transactional writes + compensating worker to reconcile inconsistent groups | Operational resilience |
| Driver tries going available while still in shared group | Block with active-ride guard | Dispatch integrity |

## State Handling Rules

### Group states
- `forming`
- `offering`
- `accepted`
- `in_progress`
- `completed`
- `cancelled`

### Member states
- `requested`
- `assigned`
- `pickup_pending`
- `picked_up`
- `dropoff_pending`
- `dropped_off`
- `cancelled`
- `no_show`

Transitions must be monotonic and auditable via ride events.

## Fare and Repricing Rules (V1)
1. Fare is computed per rider from private baseline minus shared discount policy.
2. Fare is locked for each rider at assignment acceptance.
3. If a rider exits before pickup, remaining rider may be reclassified to solo with locked-or-recomputed policy snapshot (stored in metadata).
4. If rider exits after pickup, charged amount follows in-progress cancel rules.
5. No surge recalculation after acceptance in V1.

## Timer Rules (V1)
- Shared match wait window: configurable
- Driver offer expiry: existing offer expiry policy
- Per-rider pickup no-show timer: existing no-show baseline
- Connectivity recovery grace for driver: configurable short window

All timers must be recorded in event payloads for auditability.

## API and Data Contracts Required
1. Shared quote response includes private fare reference + shared fare per rider.
2. Shared request response includes group context and rider member context.
3. Driver shared offer payload includes stop order and earning estimate.
4. Ride timeline events must include member-level transition data.
5. Error codes must distinguish rider-level vs group-level failure.

## Security and Audit Requirements
1. Protected shared endpoints require existing auth + role checks.
2. Client cannot set sensitive ownership or state transition fields directly.
3. All high-risk actions (cancel, no-show, safety override, ops override) require audit events.
4. Shared incident handling must preserve report references for moderation review.

## Monitoring Requirements
Track at minimum:
- shared match rate
- fallback-to-solo rate
- pre-pickup cancellation rate
- no-show rate by actor
- reassignment rate
- average pickup ETA delta vs solo
- complaint/report rate per 1,000 shared rides

## Out of Scope for V1
- Driver-published recurring routes
- Dynamic rider add/remove after acceptance beyond strict system policies
- Multi-hop pooling beyond 2 riders
- Price negotiation or rider bidding
- Scheduled shared rides

## Implementation Order (Binding)
1. Schema + state models for shared group/member
2. Matching compatibility + constraints
3. Shared fare computation + lock policy
4. Driver offer/accept lifecycle integration
5. No-show/cancel/shared integrity enforcement
6. Realtime + persistent notification coverage
7. Metrics + ops visibility

## Change Control
Any rule change in this document must be reflected in:
1. API contract docs
2. automated tests
3. release notes for mobile/backend teams
