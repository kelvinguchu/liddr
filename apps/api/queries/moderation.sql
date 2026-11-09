-- name: ListReportCategories :many
SELECT slug, label, applies_to, default_severity FROM report_categories
WHERE active AND display_order < 900
ORDER BY display_order;

-- name: GetReportCategory :one
SELECT slug, label, applies_to, default_severity FROM report_categories
WHERE slug = sqlc.arg(slug) AND active;

-- name: GetRideParties :one
SELECT id, rider_id, driver_id, status, fare_kes, completed_at, cancelled_at FROM rides WHERE id = sqlc.arg(id);

-- name: CountReportsSince :one
SELECT count(*) FROM reports WHERE reporter_id = sqlc.arg(reporter_id) AND created_at > sqlc.arg(since);

-- name: InsertReport :one
INSERT INTO reports (
    id, reporter_id, reported_id, category, status, severity, source, incident_type, ride_id,
    signal_key, dispute_type, requested_resolution, description, message_id, created_at, updated_at
) VALUES (
    sqlc.arg(id), sqlc.arg(reporter_id), sqlc.arg(reported_id), sqlc.arg(category), 'submitted', sqlc.arg(severity),
    sqlc.arg(source), sqlc.arg(incident_type), sqlc.arg(ride_id), sqlc.arg(signal_key), sqlc.arg(dispute_type),
    sqlc.arg(requested_resolution), sqlc.arg(description), sqlc.arg(message_id), sqlc.arg(now), sqlc.arg(now)
)
ON CONFLICT (reporter_id, ride_id, category) WHERE dispute_type IS NULL AND ride_id IS NOT NULL AND message_id IS NULL DO NOTHING
RETURNING id, status, created_at;

-- name: GetExistingRideReport :one
SELECT id, status, created_at FROM reports
WHERE reporter_id = sqlc.arg(reporter_id) AND ride_id = sqlc.arg(ride_id) AND category = sqlc.arg(category)
    AND dispute_type IS NULL AND message_id IS NULL;

-- name: SignalReportExists :one
SELECT EXISTS (
    SELECT 1 FROM reports
    WHERE reported_id = sqlc.arg(reported_id) AND signal_key = sqlc.arg(signal_key)
        AND (status IN ('submitted', 'triaged', 'under_review') OR created_at >= sqlc.arg(since))
);

-- name: ListReports :many
SELECT r.id, r.reporter_id, r.reported_id, r.category, r.status, r.severity, r.source, r.incident_type, r.ride_id,
    r.dispute_type, r.created_at
FROM reports AS r
WHERE r.status = sqlc.arg(status) AND r.dispute_type IS NULL
ORDER BY r.severity DESC, r.created_at, r.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: GetReportForUpdate :one
SELECT id, reporter_id, reported_id, category, status, severity, source, incident_type, ride_id, dispute_type,
    requested_resolution, description, assigned_reviewer_id, resolved_at, resolution_outcome, resolution_summary, created_at
FROM reports
WHERE id = sqlc.arg(id)
FOR UPDATE;

-- name: GetReport :one
SELECT id, reporter_id, reported_id, category, status, severity, source, incident_type, ride_id, dispute_type,
    requested_resolution, description, assigned_reviewer_id, resolved_at, resolution_outcome, resolution_summary, created_at
FROM reports
WHERE id = sqlc.arg(id);

-- name: TriageReport :exec
UPDATE reports
SET status = sqlc.arg(status), triaged_at = COALESCE(triaged_at, sqlc.arg(now)),
    assigned_reviewer_id = sqlc.arg(reviewer_id), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: ResolveReport :exec
UPDATE reports
SET status = sqlc.arg(status), assigned_reviewer_id = sqlc.arg(reviewer_id), resolved_at = sqlc.arg(resolved_at),
    resolution_outcome = sqlc.arg(outcome), resolution_summary = sqlc.arg(summary), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: InsertReportReview :exec
INSERT INTO report_reviews (report_id, reviewer_id, decision, status_before, status_after, reason_code, notes, created_at)
VALUES (sqlc.arg(report_id), sqlc.arg(reviewer_id), sqlc.arg(decision), sqlc.arg(status_before), sqlc.arg(status_after),
    sqlc.arg(reason_code), sqlc.arg(notes), sqlc.arg(now));

-- name: InsertEnforcement :one
INSERT INTO user_enforcements (id, user_id, report_id, actor_id, action, status, scope, reason_code, reason_text, starts_at, ends_at, created_at)
VALUES (sqlc.arg(id), sqlc.arg(user_id), sqlc.arg(report_id), sqlc.arg(actor_id), sqlc.arg(action), 'active', sqlc.arg(scope),
    sqlc.arg(reason_code), sqlc.arg(reason_text), sqlc.arg(now), sqlc.arg(ends_at), sqlc.arg(now))
RETURNING id, user_id, report_id, action, status, reason_code, starts_at, ends_at, lifted_at, created_at;

-- name: GetEnforcementForUpdate :one
SELECT id, user_id, action, status, ends_at FROM user_enforcements WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: FinishEnforcement :exec
UPDATE user_enforcements
SET status = sqlc.arg(status), lifted_at = sqlc.arg(now), lifted_by = sqlc.arg(lifted_by)
WHERE id = sqlc.arg(id);

-- name: ListActiveEnforcementActions :many
SELECT action FROM user_enforcements WHERE user_id = sqlc.arg(user_id) AND status = 'active' AND scope = 'platform';

-- name: ListEnforcements :many
SELECT id, user_id, report_id, action, status, reason_code, starts_at, ends_at, lifted_at, created_at
FROM user_enforcements
WHERE status = sqlc.arg(status)
ORDER BY created_at DESC, id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ClaimDueEnforcements :many
SELECT id, user_id FROM user_enforcements
WHERE status = 'active' AND action = 'temporary_suspension' AND ends_at <= sqlc.arg(now)
ORDER BY ends_at
LIMIT sqlc.arg(batch)
FOR UPDATE SKIP LOCKED;

-- name: GetAccountStatus :one
SELECT account_status FROM users WHERE id = sqlc.arg(id);

-- name: SetAccountStatus :exec
UPDATE users SET account_status = sqlc.arg(status), updated_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: TakeDriverOffline :exec
UPDATE drivers SET is_online = false, updated_at = sqlc.arg(now) WHERE user_id = sqlc.arg(user_id);

