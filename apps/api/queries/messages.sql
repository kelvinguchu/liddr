-- name: GetRideForMessaging :one
SELECT id, rider_id, driver_id, status FROM rides WHERE id = sqlc.arg(id);

-- name: CountMessagesSince :one
SELECT count(*) FROM ride_messages WHERE sender_id = sqlc.arg(sender_id) AND created_at > sqlc.arg(since);

-- name: InsertRideMessage :one
INSERT INTO ride_messages (id, ride_id, sender_id, recipient_id, sender_role, message_type, quick_action_code, body, created_at)
VALUES (sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(sender_id), sqlc.arg(recipient_id), sqlc.arg(sender_role),
    sqlc.arg(message_type), sqlc.arg(quick_action_code), sqlc.arg(body), sqlc.arg(now))
RETURNING seq, id, sender_id, sender_role, message_type, quick_action_code, body, read_at, created_at;

-- name: ListRideMessages :many
SELECT seq, id, sender_id, sender_role, message_type, quick_action_code, body, read_at, created_at
FROM ride_messages
WHERE ride_id = sqlc.arg(ride_id) AND seq > sqlc.arg(after_seq)
    AND (sender_id <> sqlc.arg(user_id) OR hidden_for_sender_at IS NULL)
    AND (recipient_id <> sqlc.arg(user_id) OR hidden_for_recipient_at IS NULL)
ORDER BY seq
LIMIT sqlc.arg(row_limit);

-- name: CountUnreadRideMessages :one
SELECT count(*) FROM ride_messages
WHERE ride_id = sqlc.arg(ride_id) AND recipient_id = sqlc.arg(user_id) AND read_at IS NULL AND hidden_for_recipient_at IS NULL;

-- name: GetRideMessageForUpdate :one
SELECT seq, id, ride_id, sender_id, recipient_id, body, read_at
FROM ride_messages
WHERE id = sqlc.arg(id) AND ride_id = sqlc.arg(ride_id)
FOR UPDATE;

-- name: MarkRideMessageRead :exec
UPDATE ride_messages SET read_at = COALESCE(read_at, sqlc.arg(now)) WHERE id = sqlc.arg(id);

-- name: HideRideMessageForSender :exec
UPDATE ride_messages SET hidden_for_sender_at = COALESCE(hidden_for_sender_at, sqlc.arg(now)) WHERE id = sqlc.arg(id);

-- name: HideRideMessageForRecipient :exec
UPDATE ride_messages SET hidden_for_recipient_at = COALESCE(hidden_for_recipient_at, sqlc.arg(now)) WHERE id = sqlc.arg(id);

-- Distinct reporters, so one person cannot silence another by reporting alone.
-- name: CountMessageReporters :one
SELECT count(DISTINCT reporter_id) FROM reports
WHERE reported_id = sqlc.arg(reported_id) AND message_id IS NOT NULL AND created_at >= sqlc.arg(since);

-- name: HasCommunicationRestriction :one
SELECT EXISTS (
    SELECT 1 FROM user_enforcements
    WHERE user_id = sqlc.arg(user_id) AND scope = 'communication' AND status = 'active'
        AND (ends_at IS NULL OR ends_at > sqlc.arg(now))
);
