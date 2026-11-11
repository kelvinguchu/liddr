-- name: GetDisplayName :one
SELECT display_name FROM users WHERE id = sqlc.arg(id);

-- A verified driver's name was checked against their ID, so it cannot change.
-- name: SetDisplayName :execrows
UPDATE users AS u
SET display_name = sqlc.arg(display_name), updated_at = sqlc.arg(now)
WHERE u.id = sqlc.arg(id)
    AND NOT EXISTS (
        SELECT 1 FROM drivers AS d WHERE d.user_id = u.id AND d.verification_status = 'approved'
    );

-- name: GetAccountForDeletion :one
SELECT account_status, booking_restricted_until,
    EXISTS (
        SELECT 1 FROM user_roles AS r
        WHERE r.user_id = u.id AND r.revoked_at IS NULL AND r.role IN ('ops', 'admin')
    )::boolean AS is_staff
FROM users AS u
WHERE u.id = sqlc.arg(id)
FOR UPDATE;

-- name: HasActiveTrip :one
SELECT (
    EXISTS (
        SELECT 1 FROM rides AS r
        WHERE (r.rider_id = sqlc.arg(id) OR r.driver_id = sqlc.arg(id))
            AND r.status IN ('searching', 'accepted', 'driver_arriving', 'arrived', 'in_progress')
    ) OR EXISTS (
        SELECT 1 FROM shared_members AS m
        WHERE m.rider_id = sqlc.arg(id)
            AND m.status NOT IN ('dropped_off', 'cancelled', 'no_show')
    )
)::boolean AS active;

-- name: AnonymizeUser :exec
UPDATE users
SET phone = NULL, email = NULL, display_name = NULL, account_status = 'deactivated',
    deleted_at = sqlc.arg(now), updated_at = sqlc.arg(now)
WHERE id = sqlc.arg(id);

-- name: DeleteAuthIdentities :exec
DELETE FROM auth_identities WHERE user_id = sqlc.arg(id);

-- name: RevokeUserSessions :exec
UPDATE auth_sessions
SET revoked_at = sqlc.arg(now), revoked_reason = sqlc.arg(reason)
WHERE user_id = sqlc.arg(id) AND revoked_at IS NULL;

-- name: RevokeUserPushTokens :exec
UPDATE push_tokens SET revoked_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(id) AND revoked_at IS NULL;

-- name: DeleteUserNotifications :exec
DELETE FROM notifications WHERE user_id = sqlc.arg(id);

-- name: DeleteDriverPosition :exec
DELETE FROM driver_locations WHERE driver_id = sqlc.arg(id);

-- name: RetireDriver :exec
UPDATE drivers SET is_online = false, plate_number = NULL, photo_consent_at = NULL, updated_at = sqlc.arg(now)
WHERE user_id = sqlc.arg(id);

-- name: GetDriverCard :one
SELECT u.display_name, u.rating_centi, u.rating_count, d.plate_number, c.slug AS vehicle_category,
    (SELECT count(*) FROM rides AS r WHERE r.driver_id = d.user_id AND r.status = 'completed')::integer AS completed_rides,
    COALESCE((
        SELECT v.storage_key FROM verification_documents AS v
        WHERE d.photo_consent_at IS NOT NULL AND v.driver_id = d.user_id
            AND v.document_type = 'driver_selfie_liveness' AND v.status = 'validated'
            AND v.scan_status = 'clean' AND v.purged_at IS NULL
        ORDER BY v.created_at DESC
        LIMIT 1
    ), '')::text AS photo_key
FROM drivers AS d
JOIN users AS u ON u.id = d.user_id
JOIN vehicle_categories AS c ON c.id = d.vehicle_category_id
WHERE d.user_id = sqlc.arg(id);

-- name: GetRiderCard :one
SELECT display_name, rating_centi, rating_count FROM users WHERE id = sqlc.arg(id);

-- Shared rides are paid per passenger, so their fares come from the members
-- who actually travelled.
-- name: SummarizeDriverEarnings :many
SELECT (r.completed_at AT TIME ZONE 'Africa/Nairobi')::date AS day,
    count(*)::integer AS trips,
    sum(CASE WHEN r.product_type = 'shared' THEN COALESCE((
        SELECT sum(m.fare_kes) FROM shared_members AS m
        WHERE m.ride_id = r.id AND m.status NOT IN ('cancelled', 'no_show')
    ), 0) ELSE r.fare_kes END)::integer AS total_kes
FROM rides AS r
WHERE r.driver_id = sqlc.arg(driver_id) AND r.status = 'completed' AND r.completed_at >= sqlc.arg(since)
GROUP BY day
ORDER BY day DESC;

-- Claiming and marking in one statement sends each reminder once, even when
-- instances run together. A driver who already paid for next week is skipped.
-- name: ClaimRenewalReminders :many
UPDATE subscriptions AS s
SET reminded_at = sqlc.arg(now)
WHERE s.status = 'active' AND s.reminded_at IS NULL AND s.week_start = sqlc.arg(week_start)
    AND NOT EXISTS (
        SELECT 1 FROM subscriptions AS next
        WHERE next.driver_id = s.driver_id AND next.status = 'active' AND next.week_start > s.week_start
    )
RETURNING s.driver_id;

-- Verification files go a year after the account closed. A selfie goes after
-- 30 days once it is not the driver's photo: replaced, turned down, part of a
-- rejected application, or its account closed.
-- name: ListDocumentsToPurge :many
SELECT d.id, d.storage_key
FROM verification_documents AS d
JOIN verification_applications AS a ON a.id = d.application_id
JOIN users AS u ON u.id = d.driver_id
WHERE d.purged_at IS NULL AND (
    u.deleted_at < sqlc.arg(closed_before)
    OR (d.document_type = 'driver_selfie_liveness' AND (
        u.deleted_at < sqlc.arg(selfies_before)
        OR (d.status IN ('rejected', 'expired', 'resubmission_required', 'superseded')
            AND COALESCE(d.reviewed_at, d.updated_at) < sqlc.arg(selfies_before))
        OR (a.status = 'rejected' AND a.decided_at < sqlc.arg(selfies_before))
    ))
)
ORDER BY d.created_at
LIMIT sqlc.arg(batch);

-- name: MarkDocumentPurged :exec
UPDATE verification_documents SET purged_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: SetApplicantName :exec
UPDATE users SET display_name = sqlc.arg(display_name), updated_at = sqlc.arg(now) WHERE id = sqlc.arg(id);

-- name: SetPhotoConsent :exec
UPDATE drivers SET photo_consent_at = sqlc.arg(now), updated_at = sqlc.arg(now) WHERE user_id = sqlc.arg(user_id);
