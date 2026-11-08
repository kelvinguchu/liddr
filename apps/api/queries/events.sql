-- name: PublishEvent :exec
SELECT pg_notify(sqlc.arg(channel)::text, sqlc.arg(payload)::text);

-- name: GetActiveRideForDriver :one
SELECT id, rider_id FROM rides
WHERE driver_id = sqlc.arg(driver_id)
    AND status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress');
