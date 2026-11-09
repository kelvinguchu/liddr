-- name: CountDisputesForRide :one
SELECT count(*) FROM reports
WHERE reporter_id = sqlc.arg(reporter_id) AND ride_id = sqlc.arg(ride_id) AND dispute_type IS NOT NULL;

-- name: CountDisputesSince :one
SELECT count(*) FROM reports
WHERE reporter_id = sqlc.arg(reporter_id) AND dispute_type IS NOT NULL AND created_at >= sqlc.arg(since);

-- The accused sees that a dispute exists, but never who raised it, what was
-- written, or that a safety report exists at all.
-- name: ListDisputesForUser :many
SELECT r.id, r.ride_id, r.dispute_type, r.status, r.resolution_outcome, r.created_at,
    (r.reporter_id = sqlc.arg(user_id))::boolean AS opened_by_me
FROM reports AS r
WHERE r.dispute_type IS NOT NULL AND (
    r.reporter_id = sqlc.arg(user_id)
    OR (r.reported_id = sqlc.arg(user_id) AND r.incident_type <> 'safety' AND r.dispute_type NOT IN ('safety_incident', 'wrong_driver'))
)
ORDER BY r.created_at DESC, r.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ListDisputesForOps :many
SELECT r.id, r.reporter_id, r.reported_id, r.ride_id, r.dispute_type, r.status, r.severity, r.incident_type,
    r.requested_resolution, r.description, r.created_at
FROM reports AS r
WHERE r.dispute_type IS NOT NULL AND r.status = sqlc.arg(status)
ORDER BY r.severity DESC, r.created_at, r.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: InsertCompensation :one
INSERT INTO dispute_compensations (id, report_id, ride_id, beneficiary_id, counterparty_id, actor_id, compensation_type, status, amount_kes, reason_text, created_at)
VALUES (sqlc.arg(id), sqlc.arg(report_id), sqlc.arg(ride_id), sqlc.arg(beneficiary_id), sqlc.arg(counterparty_id),
    sqlc.arg(actor_id), sqlc.arg(compensation_type), 'approved', sqlc.arg(amount_kes), sqlc.arg(reason_text), sqlc.arg(now))
RETURNING id, report_id, ride_id, beneficiary_id, compensation_type, status, amount_kes, processing_channel, processing_reference, processed_at, created_at;

-- name: GetCompensationForUpdate :one
SELECT id, report_id, ride_id, beneficiary_id, compensation_type, status, amount_kes, processing_channel, processing_reference, processed_at, created_at
FROM dispute_compensations WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: FinishCompensation :one
UPDATE dispute_compensations
SET status = sqlc.arg(status), processed_at = sqlc.arg(now), processed_by = sqlc.arg(actor),
    processing_channel = sqlc.arg(channel), processing_reference = sqlc.arg(reference)
WHERE id = sqlc.arg(id)
RETURNING id, report_id, ride_id, beneficiary_id, compensation_type, status, amount_kes, processing_channel, processing_reference, processed_at, created_at;

-- name: ListCompensationsForUser :many
SELECT id, report_id, ride_id, beneficiary_id, compensation_type, status, amount_kes, processing_channel, processing_reference, processed_at, created_at
FROM dispute_compensations
WHERE beneficiary_id = sqlc.arg(user_id)
ORDER BY created_at DESC, id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ListCompensationsForOps :many
SELECT id, report_id, ride_id, beneficiary_id, compensation_type, status, amount_kes, processing_channel, processing_reference, processed_at, created_at
FROM dispute_compensations
WHERE status = sqlc.arg(status)
ORDER BY created_at DESC, id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);
