-- name: GetActiveCategoryBySlug :one
SELECT id, slug, base_fee_cents, price_per_km_cents, price_per_min_cents, min_fare_cents,
    discount_bps, search_radius_m
FROM vehicle_categories
WHERE slug = sqlc.arg(slug) AND is_active;

-- name: CountRecentQuotes :one
SELECT count(*) FROM ride_quotes
WHERE rider_id = sqlc.arg(rider_id) AND created_at > sqlc.arg(since);

-- name: CountAvailableDrivers :one
SELECT count(*)
FROM driver_locations AS l
JOIN drivers AS d ON d.user_id = l.driver_id
JOIN users AS u ON u.id = d.user_id
WHERE l.lat BETWEEN sqlc.arg(min_lat) AND sqlc.arg(max_lat)
    AND l.lng BETWEEN sqlc.arg(min_lng) AND sqlc.arg(max_lng)
    AND l.captured_at > sqlc.arg(fresh_since)
    AND d.vehicle_category_id = sqlc.arg(vehicle_category_id)
    AND d.is_online
    AND d.verification_status = 'approved'
    AND d.subscription_status IN ('active', 'grace')
    AND u.account_status = 'active'
    AND NOT EXISTS (
        SELECT 1 FROM rides AS r
        WHERE r.driver_id = d.user_id
            AND r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
    );

-- name: CountSearchingRides :one
SELECT count(*) FROM rides
WHERE status = 'searching'
    AND vehicle_category_id = sqlc.arg(vehicle_category_id)
    AND requested_at > sqlc.arg(since)
    AND pickup_lat BETWEEN sqlc.arg(min_lat) AND sqlc.arg(max_lat)
    AND pickup_lng BETWEEN sqlc.arg(min_lng) AND sqlc.arg(max_lng);

-- name: InsertQuote :exec
INSERT INTO ride_quotes (
    id, rider_id, vehicle_category_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
    distance_m, duration_s, polyline, surge_bps, subtotal_cents, base_fare_kes, discount_kes,
    final_fare_kes, expires_at, created_at
) VALUES (
    sqlc.arg(id), sqlc.arg(rider_id), sqlc.arg(vehicle_category_id), sqlc.arg(pickup_lat),
    sqlc.arg(pickup_lng), sqlc.arg(dropoff_lat), sqlc.arg(dropoff_lng), sqlc.arg(distance_m),
    sqlc.arg(duration_s), sqlc.arg(polyline), sqlc.arg(surge_bps), sqlc.arg(subtotal_cents),
    sqlc.arg(base_fare_kes), sqlc.arg(discount_kes), sqlc.arg(final_fare_kes),
    sqlc.arg(expires_at), sqlc.arg(created_at)
);

-- name: GetQuote :one
SELECT q.id, q.rider_id, q.vehicle_category_id, q.pickup_lat, q.pickup_lng, q.dropoff_lat,
    q.dropoff_lng, q.final_fare_kes, q.expires_at, c.is_active AS category_active
FROM ride_quotes AS q
JOIN vehicle_categories AS c ON c.id = q.vehicle_category_id
WHERE q.id = sqlc.arg(id);

-- name: GetRideIDByQuote :one
SELECT id FROM rides WHERE quote_id = sqlc.arg(quote_id);

-- name: RiderHasActiveRide :one
SELECT EXISTS (
    SELECT 1 FROM rides
    WHERE rider_id = sqlc.arg(rider_id)
        AND status IN ('searching', 'accepted', 'driver_arriving', 'arrived', 'in_progress')
);

-- name: CountRecentRides :one
SELECT count(*) FROM rides
WHERE rider_id = sqlc.arg(rider_id) AND requested_at > sqlc.arg(since);

-- name: InsertRide :exec
INSERT INTO rides (
    id, rider_id, quote_id, vehicle_category_id, status, pickup_lat, pickup_lng, dropoff_lat,
    dropoff_lng, fare_kes, search_expires_at, next_dispatch_at, requested_at
) VALUES (
    sqlc.arg(id), sqlc.arg(rider_id), sqlc.arg(quote_id), sqlc.arg(vehicle_category_id),
    'searching', sqlc.arg(pickup_lat), sqlc.arg(pickup_lng), sqlc.arg(dropoff_lat),
    sqlc.arg(dropoff_lng), sqlc.arg(fare_kes), sqlc.arg(search_expires_at),
    sqlc.arg(next_dispatch_at), sqlc.arg(requested_at)
);

-- name: InsertRideEvent :exec
INSERT INTO ride_events (ride_id, from_status, to_status, actor_user_id, reason, occurred_at)
VALUES (
    sqlc.arg(ride_id), sqlc.narg(from_status), sqlc.arg(to_status), sqlc.narg(actor_user_id),
    sqlc.narg(reason), sqlc.arg(occurred_at)
);

-- name: GetRide :one
SELECT * FROM rides WHERE id = sqlc.arg(id);

-- name: GetRideForUpdate :one
SELECT * FROM rides WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: SetRideStatus :one
UPDATE rides
SET status = sqlc.arg(status),
    driver_id = COALESCE(sqlc.narg(driver_id), driver_id),
    next_dispatch_at = CASE WHEN sqlc.arg(status) = 'searching' THEN next_dispatch_at ELSE NULL END,
    accepted_at = COALESCE(sqlc.narg(accepted_at), accepted_at),
    arriving_at = COALESCE(sqlc.narg(arriving_at), arriving_at),
    arrived_at = COALESCE(sqlc.narg(arrived_at), arrived_at),
    started_at = COALESCE(sqlc.narg(started_at), started_at),
    completed_at = COALESCE(sqlc.narg(completed_at), completed_at),
    cancelled_at = COALESCE(sqlc.narg(cancelled_at), cancelled_at),
    cancelled_by = COALESCE(sqlc.narg(cancelled_by), cancelled_by),
    cancel_reason = COALESCE(sqlc.narg(cancel_reason), cancel_reason),
    payment_mode = COALESCE(sqlc.narg(payment_mode), payment_mode),
    arrival_distance_m = COALESCE(sqlc.narg(arrival_distance_m), arrival_distance_m),
    completion_distance_m = COALESCE(sqlc.narg(completion_distance_m), completion_distance_m)
WHERE id = sqlc.arg(id)
RETURNING rider_id, driver_id;

-- name: WithdrawOpenOffersForRide :many
UPDATE ride_offers
SET status = 'withdrawn', responded_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND status = 'offered'
RETURNING id, driver_id;

-- name: GetDriverLocation :one
SELECT lat, lng, captured_at FROM driver_locations WHERE driver_id = sqlc.arg(driver_id);

-- name: ResetRideForDispatch :exec
UPDATE rides
SET driver_id = NULL, accepted_at = NULL, arriving_at = NULL, arrived_at = NULL, arrival_distance_m = NULL,
    pickup_distance_m_at_accept = NULL, pickup_eta_s_at_accept = NULL,
    next_dispatch_at = sqlc.arg(now), search_expires_at = sqlc.arg(search_expires_at), dispatch_wave = 0,
    reassign_count = reassign_count + 1
WHERE id = sqlc.arg(id);

-- name: WithdrawAcceptedOffer :exec
UPDATE ride_offers SET status = 'withdrawn', responded_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND driver_id = sqlc.arg(driver_id) AND status = 'accepted';

-- name: RecordAcceptBaseline :exec
UPDATE rides SET pickup_distance_m_at_accept = sqlc.arg(distance_m), pickup_eta_s_at_accept = sqlc.arg(eta_s) WHERE id = sqlc.arg(id);

-- name: ListRidesAwaitingPickup :many
SELECT id FROM rides
WHERE status IN ('accepted', 'driver_arriving') AND accepted_at <= sqlc.arg(accepted_before)
ORDER BY accepted_at
LIMIT sqlc.arg(batch);

-- name: GetRideForUpdateSkipLocked :one
SELECT * FROM rides WHERE id = sqlc.arg(id) FOR UPDATE SKIP LOCKED;

-- name: GetRideFull :one
SELECT * FROM rides WHERE id = sqlc.arg(id);

-- name: GetCategoryRates :one
SELECT slug, base_fee_cents, price_per_km_cents, price_per_min_cents, min_fare_cents, discount_bps
FROM vehicle_categories WHERE id = sqlc.arg(id);

-- name: GetQuoteSurge :one
SELECT surge_bps FROM ride_quotes WHERE id = sqlc.arg(id);

-- name: CountDestinationChanges :one
SELECT count(*) FROM ride_destination_changes WHERE ride_id = sqlc.arg(ride_id);

-- name: LatestDestinationChangeAt :one
SELECT requested_at FROM ride_destination_changes WHERE ride_id = sqlc.arg(ride_id) ORDER BY requested_at DESC LIMIT 1;

-- A request the driver never answered must not block the rider forever.
-- name: ExpireStaleDestinationChanges :exec
UPDATE ride_destination_changes SET status = 'expired', responded_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND status = 'requested' AND requested_at <= sqlc.arg(stale_before);

-- name: HasOpenDestinationChange :one
SELECT EXISTS (SELECT 1 FROM ride_destination_changes WHERE ride_id = sqlc.arg(ride_id) AND status = 'requested');

-- name: InsertDestinationChange :exec
INSERT INTO ride_destination_changes (
    id, ride_id, requested_by, driver_id, old_dropoff_lat, old_dropoff_lng, new_dropoff_lat, new_dropoff_lng,
    old_fare_kes, new_fare_kes, status, reason_code, notes, requested_at
) VALUES (
    sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(requested_by), sqlc.arg(driver_id), sqlc.arg(old_dropoff_lat), sqlc.arg(old_dropoff_lng),
    sqlc.arg(new_dropoff_lat), sqlc.arg(new_dropoff_lng), sqlc.arg(old_fare_kes), sqlc.arg(new_fare_kes), 'requested',
    sqlc.arg(reason_code), sqlc.arg(notes), sqlc.arg(now)
);

-- name: GetDestinationChangeForUpdate :one
SELECT id, ride_id, driver_id, new_dropoff_lat, new_dropoff_lng, new_fare_kes, status, requested_at
FROM ride_destination_changes WHERE id = sqlc.arg(id) AND ride_id = sqlc.arg(ride_id) FOR UPDATE;

-- name: FinishDestinationChange :exec
UPDATE ride_destination_changes SET status = sqlc.arg(status), responded_at = sqlc.arg(now),
    reason_code = COALESCE(sqlc.narg(reason_code), reason_code)
WHERE id = sqlc.arg(id);

-- name: ApplyDestinationChange :exec
UPDATE rides SET dropoff_lat = sqlc.arg(lat), dropoff_lng = sqlc.arg(lng), fare_kes = sqlc.arg(fare_kes) WHERE id = sqlc.arg(id);

-- name: ListDestinationChanges :many
SELECT id, new_dropoff_lat, new_dropoff_lng, old_fare_kes, new_fare_kes, status, reason_code, requested_at, responded_at
FROM ride_destination_changes WHERE ride_id = sqlc.arg(ride_id) ORDER BY requested_at DESC;

-- name: ListRideHistoryForRider :many
SELECT r.id, r.status, r.fare_kes, r.payment_mode, r.requested_at, r.completed_at, r.cancelled_at, c.slug AS category
FROM rides AS r JOIN vehicle_categories AS c ON c.id = r.vehicle_category_id
WHERE r.rider_id = sqlc.arg(user_id) AND (sqlc.narg(category)::text IS NULL OR c.slug = sqlc.narg(category))
ORDER BY r.requested_at DESC, r.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ListRideHistoryForDriver :many
SELECT r.id, r.status, r.fare_kes, r.payment_mode, r.requested_at, r.completed_at, r.cancelled_at, c.slug AS category
FROM rides AS r JOIN vehicle_categories AS c ON c.id = r.vehicle_category_id
WHERE r.driver_id = sqlc.arg(user_id) AND (sqlc.narg(category)::text IS NULL OR c.slug = sqlc.narg(category))
ORDER BY r.requested_at DESC, r.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ListRideEvents :many
SELECT from_status, to_status, reason, occurred_at FROM ride_events WHERE ride_id = sqlc.arg(ride_id) ORDER BY occurred_at, id;

-- name: InsertIntegrityEvent :exec
INSERT INTO ride_integrity_events (ride_id, subject_id, subject_role, violation_type, reason_code, chargeable, waiver_code, occurred_at)
VALUES (sqlc.arg(ride_id), sqlc.arg(subject_id), sqlc.arg(subject_role), sqlc.arg(violation_type), sqlc.arg(reason_code),
    sqlc.arg(chargeable), sqlc.arg(waiver_code), sqlc.arg(now))
ON CONFLICT (ride_id) DO NOTHING;

-- name: CountChargeableEvents :one
SELECT count(*) FROM ride_integrity_events
WHERE subject_id = sqlc.arg(subject_id) AND subject_role = sqlc.arg(subject_role) AND chargeable AND occurred_at >= sqlc.arg(since);

-- name: ListChargeableEvents :many
SELECT ride_id, subject_role, violation_type, reason_code, occurred_at FROM ride_integrity_events
WHERE subject_id = sqlc.arg(subject_id) AND chargeable AND occurred_at >= sqlc.arg(since)
ORDER BY occurred_at DESC
LIMIT sqlc.arg(row_limit);

-- A restriction is only ever extended, so a short one cannot cut a long one short.
-- name: RestrictBooking :exec
UPDATE users SET booking_restricted_until = GREATEST(booking_restricted_until, sqlc.arg(until)) WHERE id = sqlc.arg(id);

-- name: GetBookingRestriction :one
SELECT booking_restricted_until FROM users WHERE id = sqlc.arg(id);
