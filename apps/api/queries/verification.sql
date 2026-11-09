-- name: GetVerificationDriver :one
SELECT user_id, verification_status, plate_number FROM drivers WHERE user_id = sqlc.arg(user_id);

-- name: SetDriverPlate :exec
UPDATE drivers SET plate_number = sqlc.arg(plate_number), updated_at = sqlc.arg(now) WHERE user_id = sqlc.arg(user_id);

-- name: SetDriverVerification :exec
UPDATE drivers
SET verification_status = sqlc.arg(status),
    is_online = CASE WHEN sqlc.arg(status)::text = 'approved' THEN is_online ELSE false END,
    updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: ListVerificationRequirements :many
SELECT document_type, label, required, requires_expiry
FROM verification_requirements
WHERE active
ORDER BY display_order;

-- name: GetVerificationRequirement :one
SELECT document_type, label, required, requires_expiry
FROM verification_requirements
WHERE document_type = sqlc.arg(document_type) AND active;

-- name: GetOpenApplication :one
SELECT id, driver_id, status, decided_at, decision_reason, created_at
FROM verification_applications
WHERE driver_id = sqlc.arg(driver_id) AND status IN ('pending', 'under_review', 'resubmission_required');

-- name: GetLatestApplication :one
SELECT id, driver_id, status, decided_at, decision_reason, created_at
FROM verification_applications
WHERE driver_id = sqlc.arg(driver_id)
ORDER BY created_at DESC
LIMIT 1;

-- name: InsertApplication :one
INSERT INTO verification_applications (id, driver_id, status, created_at, updated_at)
VALUES (sqlc.arg(id), sqlc.arg(driver_id), 'pending', sqlc.arg(now), sqlc.arg(now))
RETURNING id, driver_id, status, decided_at, decision_reason, created_at;

-- name: GetApplication :one
SELECT a.id, a.driver_id, a.status, a.decided_at, a.decision_reason, a.created_at,
    d.verification_status AS driver_status, d.plate_number, u.phone
FROM verification_applications AS a
JOIN drivers AS d ON d.user_id = a.driver_id
JOIN users AS u ON u.id = a.driver_id
WHERE a.id = sqlc.arg(id);

-- name: SetApplicationStatus :exec
UPDATE verification_applications
SET status = sqlc.arg(status), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: DecideApplication :exec
UPDATE verification_applications
SET status = sqlc.arg(status), decided_at = sqlc.arg(now), decision_reason = sqlc.arg(reason), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: ListApplications :many
SELECT a.id, a.driver_id, a.status, a.decided_at, a.decision_reason, a.created_at,
    d.verification_status AS driver_status, d.plate_number, u.phone
FROM verification_applications AS a
JOIN drivers AS d ON d.user_id = a.driver_id
JOIN users AS u ON u.id = a.driver_id
WHERE a.status = sqlc.arg(status)
ORDER BY a.created_at, a.id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: CountRecentUploads :one
SELECT count(*) FROM verification_uploads
WHERE driver_id = sqlc.arg(driver_id) AND created_at > sqlc.arg(since);

-- name: InsertUpload :exec
INSERT INTO verification_uploads (id, driver_id, document_type, storage_key, content_type, size_bytes, expires_at, created_at)
VALUES (sqlc.arg(id), sqlc.arg(driver_id), sqlc.arg(document_type), sqlc.arg(storage_key), sqlc.arg(content_type),
    sqlc.arg(size_bytes), sqlc.arg(expires_at), sqlc.arg(now));

-- name: GetUpload :one
SELECT id, driver_id, document_type, storage_key, content_type, size_bytes, expires_at, consumed_at
FROM verification_uploads
WHERE id = sqlc.arg(id) AND driver_id = sqlc.arg(driver_id);

-- name: ConsumeUpload :execrows
UPDATE verification_uploads SET consumed_at = sqlc.arg(now)
WHERE id = sqlc.arg(id) AND consumed_at IS NULL;

-- name: LastDocumentVersion :one
SELECT COALESCE(max(version), 0)::integer FROM verification_documents
WHERE driver_id = sqlc.arg(driver_id) AND document_type = sqlc.arg(document_type);

-- name: SupersedeLiveDocument :exec
UPDATE verification_documents
SET status = 'superseded', updated_at = sqlc.arg(now)
WHERE driver_id = sqlc.arg(driver_id) AND document_type = sqlc.arg(document_type) AND status <> 'superseded';

-- name: InsertDocument :one
INSERT INTO verification_documents (
    id, application_id, driver_id, document_type, version, status, storage_key, content_type,
    size_bytes, expires_on, scan_status, created_at, updated_at
) VALUES (
    sqlc.arg(id), sqlc.arg(application_id), sqlc.arg(driver_id), sqlc.arg(document_type), sqlc.arg(version),
    'scanning', sqlc.arg(storage_key), sqlc.arg(content_type), sqlc.arg(size_bytes), sqlc.arg(expires_on),
    'pending', sqlc.arg(now), sqlc.arg(now)
)
RETURNING id, document_type, version, status, expires_on, rejection_reason, created_at;

-- name: ListLiveDocuments :many
SELECT id, application_id, driver_id, document_type, version, status, content_type, size_bytes,
    expires_on, rejection_reason, scan_status, created_at
FROM verification_documents
WHERE driver_id = sqlc.arg(driver_id) AND status <> 'superseded'
ORDER BY created_at;

-- name: GetDocument :one
SELECT id, application_id, driver_id, document_type, status, storage_key, scan_status
FROM verification_documents
WHERE id = sqlc.arg(id);

-- name: GetDocumentForUpdate :one
SELECT id, application_id, driver_id, document_type, status, storage_key, scan_status
FROM verification_documents
WHERE id = sqlc.arg(id)
FOR UPDATE;

-- The WHERE clause is the lease. A worker that dies is retried once it lapses.
-- name: ClaimDocumentForScan :one
UPDATE verification_documents
SET scan_claimed_until = sqlc.arg(lease_until), scan_attempts = scan_attempts + 1
WHERE id = (
    SELECT d.id FROM verification_documents AS d
    WHERE d.scan_status = 'pending' AND (d.scan_claimed_until IS NULL OR d.scan_claimed_until <= sqlc.arg(now))
    ORDER BY d.created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
RETURNING id, application_id, driver_id, document_type, storage_key, content_type, scan_attempts;

-- name: RecordDocumentScan :exec
UPDATE verification_documents
SET status = sqlc.arg(status), scan_status = sqlc.arg(scan_status), scan_signature = sqlc.arg(scan_signature),
    rejection_reason = sqlc.arg(rejection_reason), scanned_at = sqlc.arg(now), scan_claimed_until = NULL,
    updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: RecordDocumentReview :exec
UPDATE verification_documents
SET status = sqlc.arg(status), rejection_reason = sqlc.arg(rejection_reason), reviewed_at = sqlc.arg(now),
    reviewed_by = sqlc.arg(reviewed_by), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- Expiry is tested so a document that lapses between checks cannot be approved.
-- name: CountRequirementsNotMet :one
SELECT count(*) FROM verification_requirements AS r
WHERE r.active AND r.required AND NOT EXISTS (
    SELECT 1 FROM verification_documents AS d
    WHERE d.driver_id = sqlc.arg(driver_id) AND d.document_type = r.document_type
        AND d.status = ANY (sqlc.arg(statuses)::text[])
        AND (d.expires_on IS NULL OR d.expires_on >= sqlc.arg(today))
);

-- name: InsertVerificationReview :exec
INSERT INTO verification_reviews (
    application_id, document_id, driver_id, reviewer_id, decision, status_before, status_after, reason, created_at
) VALUES (
    sqlc.arg(application_id), sqlc.arg(document_id), sqlc.arg(driver_id), sqlc.arg(reviewer_id), sqlc.arg(decision),
    sqlc.arg(status_before), sqlc.arg(status_after), sqlc.arg(reason), sqlc.arg(now)
);

-- Only live documents are considered: an old expired copy that has since been
-- replaced must never count against the driver again.
-- name: ExpireDocuments :many
UPDATE verification_documents AS d
SET status = 'expired', updated_at = sqlc.arg(now)
FROM verification_requirements AS r
WHERE r.document_type = d.document_type AND r.required AND r.requires_expiry
    AND d.status IN ('scanning', 'pending_review', 'validated', 'resubmission_required')
    AND d.expires_on < sqlc.arg(today)
RETURNING d.id, d.application_id, d.driver_id, d.status;

-- name: InsertAuditEventWithTarget :exec
INSERT INTO audit_events (action, user_id, family_id, request_id, ip, target, created_at)
VALUES (sqlc.arg(action), sqlc.arg(user_id), sqlc.arg(family_id), sqlc.arg(request_id), sqlc.arg(ip), sqlc.arg(target), sqlc.arg(now));
