-- name: CountAuditActionsSince :one
SELECT count(*) FROM audit_events
WHERE user_id = sqlc.arg(user_id) AND action = sqlc.arg(action) AND created_at > sqlc.arg(since);

-- name: GetExportProfile :one
SELECT u.phone, u.email, u.display_name, u.account_status, u.created_at, d.plate_number, d.photo_consent_at
FROM users AS u
LEFT JOIN drivers AS d ON d.user_id = u.id
WHERE u.id = sqlc.arg(id);

-- A passenger on a shared ride gets their own stops and fare, not the group's.
-- name: ListExportRides :many
SELECT r.id,
    (CASE WHEN r.driver_id = sqlc.arg(id) THEN 'driver' ELSE 'rider' END)::text AS role,
    r.status,
    COALESCE(m.pickup_lat, r.pickup_lat)::double precision AS pickup_lat,
    COALESCE(m.pickup_lng, r.pickup_lng)::double precision AS pickup_lng,
    COALESCE(m.dropoff_lat, r.dropoff_lat)::double precision AS dropoff_lat,
    COALESCE(m.dropoff_lng, r.dropoff_lng)::double precision AS dropoff_lng,
    COALESCE(m.fare_kes, r.fare_kes)::integer AS fare_kes,
    r.requested_at, r.completed_at, r.cancelled_at
FROM rides AS r
LEFT JOIN shared_members AS m ON m.ride_id = r.id AND m.rider_id = sqlc.arg(id)
WHERE r.rider_id = sqlc.arg(id) OR r.driver_id = sqlc.arg(id) OR m.ride_id IS NOT NULL
ORDER BY r.requested_at DESC
LIMIT sqlc.arg(row_limit);

-- Receipts and M-Pesa identifiers stay out of client responses.
-- name: ListExportPayments :many
SELECT channel, status, amount_kes, requested_at, paid_at
FROM subscription_payments
WHERE driver_id = sqlc.arg(id)
ORDER BY requested_at DESC
LIMIT sqlc.arg(row_limit);

-- name: ListExportDocuments :many
SELECT document_type, status, created_at, reviewed_at, expires_on
FROM verification_documents
WHERE driver_id = sqlc.arg(id)
ORDER BY created_at DESC
LIMIT sqlc.arg(row_limit);

-- name: ListExportRatings :many
SELECT ride_id, score, reason_tags, comment, submitted_at
FROM ride_ratings
WHERE rated_by = sqlc.arg(id)
ORDER BY submitted_at DESC
LIMIT sqlc.arg(row_limit);

-- Never who was reported. System signals have no reporter.
-- name: ListExportReports :many
SELECT category, status, ride_id, description, created_at
FROM reports
WHERE reporter_id = sqlc.arg(id)
ORDER BY created_at DESC
LIMIT sqlc.arg(row_limit);

-- name: ListExportMessages :many
SELECT ride_id, body, created_at
FROM ride_messages
WHERE sender_id = sqlc.arg(id)
ORDER BY created_at DESC
LIMIT sqlc.arg(row_limit);
