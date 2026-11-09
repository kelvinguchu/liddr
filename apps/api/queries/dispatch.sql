-- name: GetDriver :one
SELECT d.user_id, c.slug AS vehicle_category, d.verification_status, d.subscription_status, d.is_online
FROM drivers AS d
JOIN vehicle_categories AS c ON c.id = d.vehicle_category_id
WHERE d.user_id = sqlc.arg(user_id);

-- name: GetDriverForUpdate :one
SELECT user_id, verification_status, subscription_status, is_online
FROM drivers
WHERE user_id = sqlc.arg(user_id)
FOR UPDATE;

-- name: UpsertDriverCategory :execrows
INSERT INTO drivers (user_id, vehicle_category_id)
VALUES (sqlc.arg(user_id), sqlc.arg(vehicle_category_id))
ON CONFLICT (user_id) DO UPDATE
SET vehicle_category_id = EXCLUDED.vehicle_category_id, updated_at = now()
WHERE drivers.verification_status IN ('pending', 'rejected');

-- name: SetDriverOnline :exec
UPDATE drivers SET is_online = sqlc.arg(is_online), updated_at = now() WHERE user_id = sqlc.arg(user_id);

-- name: DriverHasActiveRide :one
SELECT EXISTS (
    SELECT 1 FROM rides
    WHERE driver_id = sqlc.arg(driver_id)
        AND status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
);

-- The WHERE on the update is the per-driver ping limit. Concurrent pings cannot
-- pass it together because the conflicting row is locked.
-- name: UpsertDriverLocation :execrows
INSERT INTO driver_locations (driver_id, lat, lng, captured_at)
SELECT d.user_id, sqlc.arg(lat), sqlc.arg(lng), sqlc.arg(now)
FROM drivers AS d
WHERE d.user_id = sqlc.arg(driver_id)
    AND (d.is_online OR EXISTS (
        SELECT 1 FROM rides AS r
        WHERE r.driver_id = d.user_id
            AND r.status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress')
    ))
ON CONFLICT (driver_id) DO UPDATE
SET lat = EXCLUDED.lat, lng = EXCLUDED.lng, captured_at = EXCLUDED.captured_at
WHERE driver_locations.captured_at <= sqlc.arg(limit_before);

-- name: ClaimDueRide :one
SELECT r.id, r.status, r.pickup_lat, r.pickup_lng, r.search_expires_at, r.dispatch_wave,
    r.vehicle_category_id, c.search_radius_m
FROM rides AS r
JOIN vehicle_categories AS c ON c.id = r.vehicle_category_id
WHERE r.next_dispatch_at IS NOT NULL AND r.next_dispatch_at <= sqlc.arg(now)
ORDER BY r.next_dispatch_at
LIMIT 1
FOR UPDATE OF r SKIP LOCKED;

-- name: ExpireOffersForRide :many
UPDATE ride_offers
SET status = 'expired', responded_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND status = 'offered' AND expires_at <= sqlc.arg(now)
RETURNING id, driver_id;

-- name: EarliestOpenOfferExpiry :one
SELECT expires_at FROM ride_offers
WHERE ride_id = sqlc.arg(ride_id) AND status = 'offered'
ORDER BY expires_at
LIMIT 1;

-- name: ScheduleDispatch :exec
UPDATE rides
SET next_dispatch_at = sqlc.arg(next_dispatch_at), dispatch_wave = sqlc.arg(dispatch_wave)
WHERE id = sqlc.arg(id);

-- name: ListDriverCandidates :many
SELECT l.driver_id, l.lat, l.lng, u.rating_centi, u.rating_count
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
    )
    AND NOT EXISTS (
        SELECT 1 FROM ride_offers AS o
        WHERE o.driver_id = d.user_id
            AND (o.status = 'offered' OR o.ride_id = sqlc.arg(ride_id))
    )
LIMIT 200;

-- name: InsertOffer :execrows
INSERT INTO ride_offers (id, ride_id, driver_id, status, distance_m, offered_at, expires_at)
VALUES (
    sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(driver_id), 'offered', sqlc.arg(distance_m),
    sqlc.arg(offered_at), sqlc.arg(expires_at)
)
ON CONFLICT DO NOTHING;

-- name: GetOfferOwner :one
SELECT ride_id, driver_id FROM ride_offers WHERE id = sqlc.arg(id);

-- name: GetOfferForUpdate :one
SELECT id, ride_id, driver_id, status, expires_at
FROM ride_offers
WHERE id = sqlc.arg(id)
FOR UPDATE;

-- name: SetOfferStatus :exec
UPDATE ride_offers
SET status = sqlc.arg(status), responded_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: MakeDispatchDueNow :exec
UPDATE rides SET next_dispatch_at = sqlc.arg(now)
WHERE id = sqlc.arg(id) AND status = 'searching';

-- Pickup is shown so a driver can decide. Dropoff is shown only after accepting.
-- name: ListOpenOffersForDriver :many
SELECT o.id, o.ride_id, o.distance_m, o.expires_at, r.pickup_lat, r.pickup_lng, COALESCE((SELECT sum(m.fare_kes)::integer FROM shared_members AS m WHERE m.ride_id = r.id AND m.status NOT IN ('cancelled', 'no_show')), r.fare_kes)::integer AS fare_kes
FROM ride_offers AS o
JOIN rides AS r ON r.id = o.ride_id
WHERE o.driver_id = sqlc.arg(driver_id) AND o.status = 'offered' AND o.expires_at > sqlc.arg(now);
