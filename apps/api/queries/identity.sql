-- name: CountEmailChallengesByIP :one
SELECT count(*) FROM email_challenges WHERE ip_hash = sqlc.arg(ip_hash) AND created_at > sqlc.arg(since);

-- name: ListRecentEmailChallenges :many
SELECT created_at, delivery_failed_at FROM email_challenges
WHERE email = sqlc.arg(email) AND created_at > sqlc.arg(since)
ORDER BY created_at DESC;

-- name: CloseOpenEmailChallenges :exec
UPDATE email_challenges SET closed_at = sqlc.arg(now) WHERE email = sqlc.arg(email) AND closed_at IS NULL;

-- name: InsertEmailChallenge :exec
INSERT INTO email_challenges (id, email, code_hash, ip_hash, expires_at, created_at)
VALUES (sqlc.arg(id), sqlc.arg(email), sqlc.arg(code_hash), sqlc.arg(ip_hash), sqlc.arg(expires_at), sqlc.arg(created_at));

-- name: MarkEmailChallengeFailed :exec
UPDATE email_challenges SET delivery_failed_at = sqlc.arg(now), closed_at = COALESCE(closed_at, sqlc.arg(now)) WHERE id = sqlc.arg(id);

-- name: GetEmailChallengeForUpdate :one
SELECT id, email, code_hash, attempts, expires_at, closed_at FROM email_challenges WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: RecordEmailChallengeFailure :exec
UPDATE email_challenges
SET attempts = attempts + 1,
    closed_at = CASE WHEN attempts + 1 >= sqlc.arg(max_attempts)::integer THEN sqlc.arg(now) ELSE closed_at END
WHERE id = sqlc.arg(id);

-- name: CloseEmailChallenge :exec
UPDATE email_challenges SET closed_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: UpsertUserByEmail :one
INSERT INTO users (email) VALUES (sqlc.arg(email))
ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
RETURNING id, account_status, (xmax = 0)::boolean AS created;

-- name: CreateUserWithoutContact :one
INSERT INTO users (phone, email) VALUES (NULL, NULL) RETURNING id, account_status;

-- name: GetIdentityUser :one
SELECT i.user_id, u.account_status
FROM auth_identities AS i JOIN users AS u ON u.id = i.user_id
WHERE i.provider = sqlc.arg(provider) AND i.subject = sqlc.arg(subject);

-- name: InsertIdentity :exec
INSERT INTO auth_identities (provider, subject, user_id, created_at, last_used_at)
VALUES (sqlc.arg(provider), sqlc.arg(subject), sqlc.arg(user_id), sqlc.arg(now), sqlc.arg(now))
ON CONFLICT (provider, subject) DO UPDATE SET last_used_at = EXCLUDED.last_used_at;

-- name: TouchIdentity :exec
UPDATE auth_identities SET last_used_at = sqlc.arg(now) WHERE provider = sqlc.arg(provider) AND subject = sqlc.arg(subject);
