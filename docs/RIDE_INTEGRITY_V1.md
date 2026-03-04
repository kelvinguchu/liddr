# Ride Integrity v1

Status: Approved for implementation  
Date: 2026-03-03  
Scope: API backend (Phoenix/Elixir), mobile contract inputs, ops controls

## 1. Why this exists

Current dispatch and execution flow is working, but rider/driver trust breaks in these cases:

- Rider cancels without driver clearly seeing it
- Driver claims arrival/completion while rider disputes location/outcome
- Mid-trip destination changes are handled informally (chat/call), causing fare disputes
- Timeline events are real-time but not yet delivery-guaranteed across socket disconnects/push
- Shared rides need different rules from single-passenger rides

This spec defines strict behavior so trip outcomes are auditable, fair, and hard to abuse.

## 2. Current baseline (already in code)

- Ride states exist: `requested -> offering -> accepted -> driver_arriving -> arrived -> in_progress -> completed|cancelled`
- Driver offer lifecycle exists with expiry, reject, and next-wave dispatch
- Rider and driver cancellation endpoints exist
- Ride timeline events exist (`ride_events`) with channel replay (`ride:*`, `timeline.sync`)
- Driver lock/unlock (`current_ride_id`, availability gating) exists

## 3. v1 additions (what we add now)

### A. Cancellation contract + guaranteed awareness

1. Enforce cancellation policy by ride state:
- `requested|offering`: no penalty, immediate cancel
- `accepted|driver_arriving`: standard cancellation reason required
- `arrived`: no-show timer aware logic (see section C)
- `in_progress`: rider cancel disabled (must use support/report flow), driver cancel restricted to emergency reason set

2. Add reliable cancellation delivery tracking:
- Persist one notification record per recipient per critical event (`ride_cancelled`, `rider_no_show`, `driver_cancelled`)
- Delivery channels in order: socket -> push -> polling fallback
- Mark per-channel status: `pending|sent|acked|failed`

3. Add explicit cancellation reason taxonomy:
- `rider_changed_mind`, `driver_too_far`, `driver_not_moving`, `cannot_contact_driver`, `safety_concern`, `rider_no_show`, `vehicle_issue`, `emergency`
- Free-text note optional, reason code mandatory

### B. Pickup/dropoff truth rules

1. Arrival geofence gate:
- Driver can mark `arrived` only if within configurable pickup radius (default 120m)

2. Trip start gate:
- Driver can mark `in_progress` only after `arrived`
- Optional rider confirmation path (PIN) enabled by feature flag

3. Completion geofence gate:
- Driver can complete only if near final dropoff radius (default 180m)
- If outside radius, require rider-confirm override or ops-reasoned override

4. Capture proof in ride events:
- `driver_arrived` and `ride_completed` payload must include driver coordinates, distance_to_target_m, and source timestamp

### C. No-show window (anti-abuse)

1. Add no-show timer policy:
- Timer starts at `arrived_at`
- Minimum wait before no-show allowed: default 5 minutes

2. `POST /api/rides/:ride_id/no-show` allowed only when:
- Status is `arrived`
- Wait threshold elapsed
- Driver still within pickup radius

3. Store no-show evidence:
- `arrived_at`, `no_show_marked_at`, sampled driver location, elapsed seconds

### D. Mid-trip destination change (in-app only)

1. New flow:
- Rider requests destination change (`in_progress` only)
- Backend computes new route/fare delta
- Driver accepts/rejects change
- On accept: ride dropoff updates and timeline event emitted
- On reject: ride continues on prior destination

2. Rules:
- Max 2 destination changes per ride in v1
- Disabled for shared ride products
- All changes require structured reason and are fully auditable

3. Fare handling:
- Recompute using current pricing pipeline (route + time + demand + discount)
- Persist old fare, new fare, and delta

### E. Persistent journey notifications

1. Critical journey events:
- `ride_assigned`, `driver_arriving`, `driver_arrived`, `trip_started`, `ride_cancelled`, `ride_completed`

2. Server requirements:
- Persist outbound notification intent
- Retry push delivery via job worker
- Keep timeline as source of truth for client re-sync

3. Client contract:
- Mobile must always reconnect and call `timeline.sync` with last cursor
- Sticky trip UI (Android ongoing notification / iOS Live Activity) driven by server timeline events

### F. Shared ride model (separate product track)

Shared rides are not a toggle on normal rides.

v1 foundation only:
- Add ride `product_type` with values: `solo`, `shared`
- Shared rides disable destination change and tighten pickup timer
- Matching/route pooling logic remains v2 (not in this implementation batch)

## 4. Database changes

### 4.1 `rides` table additions

- `product_type` (`solo` default, `shared`)
- `arrival_distance_m` (last computed on `arrived`)
- `completion_distance_m` (last computed on `completed`)
- `cancellation_reason_code`
- `cancelled_by_user_id`
- `no_show_marked_at`

### 4.2 New `ride_destination_changes` table

- `id`, `ride_id`, `requested_by_user_id`, `driver_id`
- `old_dropoff_lat/lng`, `new_dropoff_lat/lng`
- `old_fare_kes`, `new_fare_kes`, `fare_delta_kes`
- `status` (`requested|accepted|rejected|expired`)
- `reason_code`, `notes`
- `requested_at`, `responded_at`, timestamps

### 4.3 New `ride_notifications` table

- `id`, `ride_id`, `recipient_user_id`, `event_type`
- `socket_status`, `push_status`, `poll_status`
- `last_attempt_at`, `acked_at`, `attempt_count`
- `payload` (redacted), timestamps

## 5. API changes

### 5.1 Existing endpoint hardening

- `POST /api/rides/:ride_id/cancel`
  - Require reason code
  - Enforce state policy matrix

- `POST /api/rides/:ride_id/arrived`
  - Enforce pickup geofence

- `POST /api/rides/:ride_id/complete`
  - Enforce dropoff geofence or explicit override reason

- `POST /api/rides/:ride_id/no-show`
  - Enforce wait timer and pickup geofence

### 5.2 New endpoints

- `POST /api/rides/:ride_id/destination-change-requests` (rider)
- `POST /api/rides/:ride_id/destination-change-requests/:id/accept` (driver)
- `POST /api/rides/:ride_id/destination-change-requests/:id/reject` (driver)
- `GET /api/rides/:ride_id/notifications` (ops/admin diagnostics only)

## 6. Config/env additions

- `RIDE_PICKUP_ARRIVAL_RADIUS_M=120`
- `RIDE_DROPOFF_COMPLETION_RADIUS_M=180`
- `RIDE_NO_SHOW_WAIT_SECONDS=300`
- `RIDE_DESTINATION_CHANGE_MAX_COUNT=2`
- `RIDE_REQUIRE_REASON_ON_CANCEL=true`
- `RIDE_REQUIRE_GEOFENCE_ON_COMPLETE=true`

## 7. Event model additions (`ride_events.event_type`)

- `destination_change_requested`
- `destination_change_accepted`
- `destination_change_rejected`
- `ride_notification_queued`
- `ride_notification_acked`
- `ride_no_show_marked`
- `ride_completion_override_used`

## 8. Testing requirements

1. Cancellation:
- Rider cancel broadcast reaches driver path + persisted notification row
- Driver receives cancellation after reconnect via timeline sync

2. Geofence:
- `arrived` rejected outside radius
- `complete` rejected outside radius unless override path enabled

3. No-show:
- Reject before wait threshold
- Accept after threshold with valid proximity evidence

4. Destination change:
- Accept/reject flow updates ride + events
- Shared product rejects destination change request

5. Reliability:
- Retry logic for pending notification records
- Idempotency under duplicate callbacks/events

## 9. Rollout order

1. Cancellation hardening + reason codes + delivery tracking
2. Arrival/completion geofence enforcement
3. No-show timer enforcement
4. Destination change workflow
5. Shared ride foundation fields and guards
6. Push retry worker + ops notification diagnostics

## 10. Out of scope for this batch

- Full pooled/shared dispatch and multi-rider route optimization
- Rider billing penalty engine for cancellation/no-show fees
- Public reliability score exposure to users

