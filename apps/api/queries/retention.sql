-- name: DeleteExpiredAuthChallenges :execrows
DELETE FROM auth_challenges WHERE id IN (
    SELECT c.id FROM auth_challenges AS c WHERE c.expires_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- name: DeleteExpiredEmailChallenges :execrows
DELETE FROM email_challenges WHERE id IN (
    SELECT c.id FROM email_challenges AS c WHERE c.expires_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- A session row is needed until its whole family has aged out, so that reuse
-- of an old refresh token is still recognized.
-- name: DeleteExpiredSessions :execrows
DELETE FROM auth_sessions WHERE id IN (
    SELECT s.id FROM auth_sessions AS s WHERE s.refresh_expires_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- name: DeleteOldAuditEvents :execrows
DELETE FROM audit_events WHERE id IN (
    SELECT a.id FROM audit_events AS a WHERE a.created_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- name: DeleteOldNotifications :execrows
DELETE FROM notifications WHERE id IN (
    SELECT n.id FROM notifications AS n WHERE n.created_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- Quotes that became rides are kept with them.
-- name: DeleteUnusedQuotes :execrows
DELETE FROM ride_quotes WHERE id IN (
    SELECT q.id FROM ride_quotes AS q
    WHERE q.created_at < sqlc.arg(before) AND NOT EXISTS (SELECT 1 FROM rides AS r WHERE r.quote_id = q.id)
    LIMIT sqlc.arg(batch)
);

-- A report keeps its reference, cleared by ON DELETE SET NULL.
-- name: DeleteOldRideMessages :execrows
DELETE FROM ride_messages WHERE seq IN (
    SELECT m.seq FROM ride_messages AS m
    JOIN rides AS r ON r.id = m.ride_id
    WHERE COALESCE(r.completed_at, r.cancelled_at) < sqlc.arg(before)
    LIMIT sqlc.arg(batch)
);

-- name: DeleteUnusedVerificationUploads :execrows
DELETE FROM verification_uploads WHERE id IN (
    SELECT u.id FROM verification_uploads AS u WHERE u.consumed_at IS NULL AND u.expires_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- name: DeleteUnusedProofUploads :execrows
DELETE FROM send_proof_uploads WHERE id IN (
    SELECT u.id FROM send_proof_uploads AS u WHERE u.consumed_at IS NULL AND u.expires_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);

-- name: DeleteOldUnmatchedCallbacks :execrows
DELETE FROM mpesa_unmatched_callbacks WHERE id IN (
    SELECT c.id FROM mpesa_unmatched_callbacks AS c WHERE c.received_at < sqlc.arg(before) LIMIT sqlc.arg(batch)
);
