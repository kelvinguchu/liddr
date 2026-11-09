-- name: GetStaffUserByPhone :one
SELECT u.id, u.account_status
FROM users AS u
WHERE u.phone = sqlc.arg(phone) AND EXISTS (
    SELECT 1 FROM user_roles AS r
    WHERE r.user_id = u.id AND r.role IN ('ops', 'admin') AND r.revoked_at IS NULL
);

-- name: GrantRole :exec
INSERT INTO user_roles (user_id, role)
VALUES (sqlc.arg(user_id), sqlc.arg(role))
ON CONFLICT (user_id, role) DO UPDATE SET revoked_at = NULL, granted_at = now();

-- name: GetFamilyStartedAt :one
SELECT min(created_at)::timestamptz AS started_at FROM auth_sessions WHERE family_id = sqlc.arg(family_id);

-- name: GetTOTPForUpdate :one
SELECT user_id, secret_sealed, confirmed_at, last_counter, failed_attempts, locked_until,
    pending_secret_sealed, pending_expires_at, pending_attempts
FROM totp_credentials
WHERE user_id = sqlc.arg(user_id)
FOR UPDATE;

-- name: BeginTOTPEnrolment :exec
INSERT INTO totp_credentials (
    user_id, pending_secret_sealed, pending_expires_at, pending_attempts, created_at, updated_at
) VALUES (sqlc.arg(user_id), sqlc.arg(sealed), sqlc.arg(expires_at), 0, sqlc.arg(now), sqlc.arg(now))
ON CONFLICT (user_id) DO UPDATE SET
    pending_secret_sealed = EXCLUDED.pending_secret_sealed,
    pending_expires_at = EXCLUDED.pending_expires_at,
    pending_attempts = 0,
    updated_at = EXCLUDED.updated_at;

-- name: ConfirmTOTPEnrolment :exec
UPDATE totp_credentials
SET secret_sealed = pending_secret_sealed,
    confirmed_at = sqlc.arg(now),
    last_counter = sqlc.arg(counter),
    failed_attempts = 0,
    locked_until = NULL,
    pending_secret_sealed = NULL,
    pending_expires_at = NULL,
    pending_attempts = 0,
    updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: RecordPendingTOTPFailure :exec
UPDATE totp_credentials
SET pending_attempts = pending_attempts + 1, updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: DiscardPendingTOTP :exec
UPDATE totp_credentials
SET pending_secret_sealed = NULL, pending_expires_at = NULL, pending_attempts = 0, updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: RecordTOTPFailure :exec
UPDATE totp_credentials
SET failed_attempts = sqlc.arg(failed_attempts), locked_until = sqlc.arg(locked_until), updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: RecordTOTPSuccess :exec
UPDATE totp_credentials
SET last_counter = sqlc.arg(counter), failed_attempts = 0, locked_until = NULL, updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id);

-- name: ClearTOTP :exec
DELETE FROM totp_credentials WHERE user_id = sqlc.arg(user_id);
