-- name: LockKey :exec
SELECT pg_advisory_xact_lock(hashtextextended(sqlc.arg(key)::text, 0));

-- The per-phone cooldown bounds how many rows this can return.
-- name: ListRecentChallenges :many
SELECT created_at, delivery_failed_at
FROM auth_challenges
WHERE phone = sqlc.arg(phone) AND created_at > sqlc.arg(since)
ORDER BY created_at DESC;

-- name: CountChallengesByIP :one
SELECT count(*)
FROM auth_challenges
WHERE ip_hash = sqlc.arg(ip_hash) AND created_at > sqlc.arg(since);

-- name: CloseOpenChallenges :exec
UPDATE auth_challenges
SET closed_at = sqlc.arg(now)
WHERE phone = sqlc.arg(phone) AND closed_at IS NULL;

-- name: InsertChallenge :exec
INSERT INTO auth_challenges (id, phone, requested_role, code_hash, ip_hash, expires_at, created_at)
VALUES (
    sqlc.arg(id), sqlc.arg(phone), sqlc.arg(requested_role), sqlc.arg(code_hash),
    sqlc.arg(ip_hash), sqlc.arg(expires_at), sqlc.arg(created_at)
);

-- name: MarkChallengeDeliveryFailed :exec
UPDATE auth_challenges
SET delivery_failed_at = sqlc.arg(now), closed_at = COALESCE(closed_at, sqlc.arg(now))
WHERE id = sqlc.arg(id);

-- name: GetChallengeForUpdate :one
SELECT id, phone, requested_role, code_hash, attempts, expires_at, closed_at
FROM auth_challenges
WHERE id = sqlc.arg(id)
FOR UPDATE;

-- name: RecordChallengeFailure :exec
UPDATE auth_challenges
SET attempts = attempts + 1,
    closed_at = CASE WHEN attempts + 1 >= sqlc.arg(max_attempts)::integer THEN sqlc.arg(now) ELSE closed_at END
WHERE id = sqlc.arg(id);

-- name: CloseChallenge :exec
UPDATE auth_challenges SET closed_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: UpsertUserByPhone :one
INSERT INTO users (phone)
VALUES (sqlc.arg(phone))
ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone
RETURNING id, account_status, (xmax = 0)::boolean AS created;

-- name: GrantInitialRole :exec
INSERT INTO user_roles (user_id, role)
VALUES (sqlc.arg(user_id), sqlc.arg(role))
ON CONFLICT (user_id, role) DO NOTHING;

-- name: ListActiveRoles :many
SELECT role FROM user_roles
WHERE user_id = sqlc.arg(user_id) AND revoked_at IS NULL
ORDER BY role;

-- name: GetUserAccountStatus :one
SELECT account_status FROM users WHERE id = sqlc.arg(id);

-- name: InsertSession :exec
INSERT INTO auth_sessions (
    id, family_id, user_id, access_token_hash, refresh_token_hash,
    access_expires_at, refresh_expires_at, created_at
) VALUES (
    sqlc.arg(id), sqlc.arg(family_id), sqlc.arg(user_id), sqlc.arg(access_token_hash),
    sqlc.arg(refresh_token_hash), sqlc.arg(access_expires_at), sqlc.arg(refresh_expires_at),
    sqlc.arg(created_at)
);

-- name: GetFamilyByRefreshHash :one
SELECT family_id FROM auth_sessions WHERE refresh_token_hash = sqlc.arg(hash);

-- name: GetSessionByRefreshHash :one
SELECT id, family_id, user_id, refresh_expires_at, revoked_at, revoked_reason, replaced_by_id
FROM auth_sessions
WHERE refresh_token_hash = sqlc.arg(hash);

-- name: GetSessionRevokedAt :one
SELECT revoked_at FROM auth_sessions WHERE id = sqlc.arg(id);

-- name: MarkSessionRotated :exec
UPDATE auth_sessions
SET revoked_at = sqlc.arg(now), revoked_reason = 'rotated', replaced_by_id = sqlc.arg(replaced_by_id)
WHERE id = sqlc.arg(id);

-- name: SetSessionReplacement :exec
UPDATE auth_sessions SET replaced_by_id = sqlc.arg(replaced_by_id) WHERE id = sqlc.arg(id);

-- name: SupersedeSession :exec
UPDATE auth_sessions
SET revoked_at = sqlc.arg(now), revoked_reason = 'superseded'
WHERE id = sqlc.arg(id) AND revoked_at IS NULL;

-- name: RevokeFamily :exec
UPDATE auth_sessions
SET revoked_at = sqlc.arg(now), revoked_reason = sqlc.arg(reason)
WHERE family_id = sqlc.arg(family_id) AND revoked_at IS NULL;

-- name: AuthenticateAccessToken :one
SELECT s.id AS session_id, s.family_id, s.user_id, u.account_status, COALESCE(u.phone, '')::text AS phone,
    EXISTS (
        SELECT 1 FROM totp_credentials AS t
        WHERE t.user_id = s.user_id AND t.confirmed_at IS NOT NULL
    )::boolean AS mfa_enrolled,
    ARRAY(
        SELECT r.role FROM user_roles AS r
        WHERE r.user_id = s.user_id AND r.revoked_at IS NULL
        ORDER BY r.role
    )::text[] AS roles
FROM auth_sessions AS s
JOIN users AS u ON u.id = s.user_id
WHERE s.access_token_hash = sqlc.arg(hash)
    AND s.revoked_at IS NULL
    AND s.access_expires_at > sqlc.arg(now);

-- name: InsertAuditEvent :exec
INSERT INTO audit_events (action, user_id, family_id, request_id, ip, created_at)
VALUES (
    sqlc.arg(action), sqlc.arg(user_id), sqlc.arg(family_id), sqlc.arg(request_id),
    sqlc.arg(ip), sqlc.arg(created_at)
);
