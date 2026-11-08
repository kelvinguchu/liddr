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
