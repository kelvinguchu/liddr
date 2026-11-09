-- name: ListSharedCandidates :many
SELECT r.id, r.pickup_lat, r.pickup_lng, r.dropoff_lat, r.dropoff_lng, r.requested_at
FROM rides AS r
WHERE r.product_type = 'shared' AND r.status = 'searching' AND r.vehicle_category_id = sqlc.arg(vehicle_category_id)
    AND r.rider_id <> sqlc.arg(rider_id) AND r.requested_at >= sqlc.arg(since)
ORDER BY r.requested_at DESC
LIMIT 25;

-- name: ListSharedMembers :many
SELECT id, ride_id, rider_id, status, fare_kes, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, requested_at
FROM shared_members
WHERE ride_id = sqlc.arg(ride_id)
ORDER BY requested_at, id;

-- name: InsertSharedMember :exec
INSERT INTO shared_members (id, ride_id, rider_id, quote_id, status, fare_kes, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, requested_at)
VALUES (sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(rider_id), sqlc.arg(quote_id), 'requested', sqlc.arg(fare_kes), sqlc.arg(pickup_lat),
    sqlc.arg(pickup_lng), sqlc.arg(dropoff_lat), sqlc.arg(dropoff_lng), sqlc.arg(now));

-- name: GetRideIDByMemberQuote :one
SELECT ride_id FROM shared_members WHERE quote_id = sqlc.arg(quote_id);

-- name: GetSharedMemberForUpdate :one
SELECT id, ride_id, rider_id, status, fare_kes, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, pickup_arrived_at
FROM shared_members
WHERE id = sqlc.arg(id) AND ride_id = sqlc.arg(ride_id)
FOR UPDATE;

-- name: GetSharedMemberByRider :one
SELECT id, status, fare_kes, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng
FROM shared_members
WHERE ride_id = sqlc.arg(ride_id) AND rider_id = sqlc.arg(rider_id);

-- name: SetSharedMemberStatus :exec
UPDATE shared_members
SET status = sqlc.arg(status),
    pickup_arrived_at = COALESCE(sqlc.narg(pickup_arrived_at), pickup_arrived_at),
    picked_up_at = COALESCE(sqlc.narg(picked_up_at), picked_up_at),
    dropped_off_at = COALESCE(sqlc.narg(dropped_off_at), dropped_off_at),
    ended_at = COALESCE(sqlc.narg(ended_at), ended_at)
WHERE id = sqlc.arg(id);

-- name: PromoteSharedRider :exec
UPDATE rides
SET rider_id = sqlc.arg(rider_id), pickup_lat = sqlc.arg(pickup_lat), pickup_lng = sqlc.arg(pickup_lng),
    dropoff_lat = sqlc.arg(dropoff_lat), dropoff_lng = sqlc.arg(dropoff_lng), fare_kes = sqlc.arg(fare_kes)
WHERE id = sqlc.arg(id);

-- name: ListActiveMemberRiders :many
SELECT rider_id FROM shared_members
WHERE ride_id = sqlc.arg(ride_id) AND status IN ('requested', 'assigned', 'pickup_pending', 'picked_up');

-- name: SetMembersAssigned :exec
UPDATE shared_members SET status = 'assigned' WHERE ride_id = sqlc.arg(ride_id) AND status = 'requested';

-- name: SetMembersRequested :exec
UPDATE shared_members SET status = 'requested' WHERE ride_id = sqlc.arg(ride_id) AND status = 'assigned';

-- name: CancelActiveMembers :exec
UPDATE shared_members SET status = 'cancelled', ended_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND status IN ('requested', 'assigned', 'pickup_pending', 'picked_up');

-- name: InsertMemberRatingActions :exec
INSERT INTO rating_actions (ride_id, rated_by, rated_user, rater_role, status, due_at)
SELECT m.ride_id, m.rider_id, sqlc.arg(driver_id)::uuid, 'rider', 'pending', sqlc.arg(due_at)::timestamptz
FROM shared_members AS m
WHERE m.ride_id = sqlc.arg(ride_id) AND m.status = 'dropped_off'
ON CONFLICT (ride_id, rated_by) DO NOTHING;

-- name: IsSharedMember :one
SELECT EXISTS (
    SELECT 1 FROM shared_members
    WHERE ride_id = sqlc.arg(ride_id) AND rider_id = sqlc.arg(rider_id) AND status NOT IN ('cancelled')
);

-- name: GetSharedMemberFare :one
SELECT fare_kes FROM shared_members WHERE ride_id = sqlc.arg(ride_id) AND rider_id = sqlc.arg(rider_id);
