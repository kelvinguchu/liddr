-- name: InsertNotifications :exec
INSERT INTO notifications (user_id, event_type, ride_id, offer_id, status)
SELECT recipient, sqlc.arg(event_type), sqlc.arg(ride_id), sqlc.arg(offer_id), sqlc.arg(status)
FROM unnest(sqlc.arg(recipients)::uuid[]) AS recipient;

-- name: ListNotifications :many
SELECT id, event_type, ride_id, offer_id, status, acked_at, created_at
FROM notifications
WHERE user_id = sqlc.arg(user_id) AND (sqlc.arg(include_acked)::boolean OR acked_at IS NULL)
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(row_limit);

-- name: CountUnackedNotifications :one
SELECT count(*) FROM notifications WHERE user_id = sqlc.arg(user_id) AND acked_at IS NULL;

-- Setting acked_at only once keeps the first acknowledgement's time.
-- name: AckNotification :execrows
UPDATE notifications
SET acked_at = COALESCE(acked_at, sqlc.arg(now))
WHERE id = sqlc.arg(id) AND user_id = sqlc.arg(user_id);

-- name: ClaimNotificationsToPush :many
UPDATE notifications
SET push_claimed_until = sqlc.arg(lease_until), push_attempts = push_attempts + 1
WHERE id IN (
    SELECT n.id FROM notifications AS n
    WHERE n.push_status = 'pending' AND (n.push_claimed_until IS NULL OR n.push_claimed_until <= sqlc.arg(now))
    ORDER BY n.created_at
    LIMIT sqlc.arg(batch)
    FOR UPDATE SKIP LOCKED
)
RETURNING id, user_id, event_type, ride_id, offer_id, status, push_attempts, created_at;

-- name: SetNotificationPushStatus :exec
UPDATE notifications SET push_status = sqlc.arg(push_status), push_claimed_until = NULL WHERE id = sqlc.arg(id);

-- A token moves to whoever registered it last, so a phone that changes hands
-- stops receiving the previous account's pushes.
-- name: UpsertPushToken :exec
INSERT INTO push_tokens (user_id, family_id, token, platform, last_seen_at, created_at)
VALUES (sqlc.arg(user_id), sqlc.arg(family_id), sqlc.arg(token), sqlc.arg(platform), sqlc.arg(now), sqlc.arg(now))
ON CONFLICT (token) DO UPDATE SET
    user_id = EXCLUDED.user_id,
    family_id = EXCLUDED.family_id,
    platform = EXCLUDED.platform,
    last_seen_at = EXCLUDED.last_seen_at,
    revoked_at = NULL;

-- name: TrimPushTokens :exec
UPDATE push_tokens AS p SET revoked_at = sqlc.arg(now)
WHERE p.user_id = sqlc.arg(user_id) AND p.revoked_at IS NULL AND p.id NOT IN (
    SELECT t.id FROM push_tokens AS t
    WHERE t.user_id = sqlc.arg(user_id) AND t.revoked_at IS NULL
    ORDER BY t.last_seen_at DESC
    LIMIT sqlc.arg(keep)
);

-- name: RevokeUserPushToken :exec
UPDATE push_tokens SET revoked_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(user_id) AND token = sqlc.arg(token) AND revoked_at IS NULL;

-- name: RevokeFamilyPushTokens :exec
UPDATE push_tokens SET revoked_at = sqlc.arg(now) WHERE family_id = sqlc.arg(family_id) AND revoked_at IS NULL;

-- name: RevokePushToken :exec
UPDATE push_tokens SET revoked_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: ListActivePushTokens :many
SELECT id, token FROM push_tokens
WHERE user_id = sqlc.arg(user_id) AND revoked_at IS NULL
ORDER BY last_seen_at DESC;
