-- name: InsertRatingActions :exec
INSERT INTO rating_actions (ride_id, rated_by, rated_user, rater_role, status, due_at)
VALUES
    (sqlc.arg(ride_id), sqlc.arg(rider_id), sqlc.arg(driver_id), 'rider', 'pending', sqlc.arg(due_at)),
    (sqlc.arg(ride_id), sqlc.arg(driver_id), sqlc.arg(rider_id), 'driver', 'pending', sqlc.arg(due_at))
ON CONFLICT (ride_id, rated_by) DO NOTHING;

-- name: ListPendingRatings :many
SELECT a.ride_id, a.rated_user, a.rater_role, a.due_at, r.completed_at
FROM rating_actions AS a
JOIN rides AS r ON r.id = a.ride_id
WHERE a.rated_by = sqlc.arg(rated_by) AND a.status = 'pending' AND a.due_at > sqlc.arg(now)
ORDER BY a.due_at, a.ride_id;

-- name: GetRatingActionForUpdate :one
SELECT ride_id, rated_by, rated_user, rater_role, status, due_at
FROM rating_actions
WHERE ride_id = sqlc.arg(ride_id) AND rated_by = sqlc.arg(rated_by)
FOR UPDATE;

-- name: ResolveRatingAction :exec
UPDATE rating_actions SET status = sqlc.arg(status), resolved_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id) AND rated_by = sqlc.arg(rated_by);

-- name: InsertRating :one
INSERT INTO ride_ratings (id, ride_id, rated_by, rated_user, score, reason_tags, comment, include_in_score, exclusion_reason, submitted_at)
VALUES (sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(rated_by), sqlc.arg(rated_user), sqlc.arg(score), sqlc.arg(reason_tags),
    sqlc.arg(comment), sqlc.arg(include_in_score), sqlc.arg(exclusion_reason), sqlc.arg(now))
RETURNING id, include_in_score;

-- Newer ratings weigh more. The prior keeps a handful of ratings from swinging
-- a new account's score. All arithmetic is in one statement, so a recalculation
-- is one query however many ratings the account has.
-- name: RecalculateRating :one
WITH stats AS (
    SELECT count(*)::integer AS rating_count,
        COALESCE(sum(r.score / (1 + (extract(epoch FROM (sqlc.arg(now)::timestamptz - r.submitted_at)) / 86400.0) * 0.01)), 0)::double precision AS weighted_sum,
        COALESCE(sum(1 / (1 + (extract(epoch FROM (sqlc.arg(now)::timestamptz - r.submitted_at)) / 86400.0) * 0.01)), 0)::double precision AS weight_total
    FROM ride_ratings AS r
    WHERE r.rated_user = sqlc.arg(user_id) AND r.include_in_score AND r.nullified_at IS NULL
)
UPDATE users AS u
SET rating_count = stats.rating_count,
    rating_centi = CASE WHEN stats.rating_count = 0 THEN NULL
        ELSE round((stats.weighted_sum + 4.8 * 20) / (stats.weight_total + 20) * 100)::integer END
FROM stats
WHERE u.id = sqlc.arg(user_id)
RETURNING u.rating_centi, u.rating_count;

-- name: GetRatingGuardrail :one
SELECT count(*) FROM ride_ratings
WHERE rated_user = sqlc.arg(rated_user) AND include_in_score AND nullified_at IS NULL AND submitted_at >= sqlc.arg(since);

-- name: CountFiveStarsSince :one
SELECT count(*) FROM ride_ratings
WHERE rated_user = sqlc.arg(rated_user) AND score = 5 AND include_in_score AND nullified_at IS NULL AND submitted_at >= sqlc.arg(since);

-- name: CountFiveStarsFromRater :one
SELECT count(*) FROM ride_ratings
WHERE rated_user = sqlc.arg(rated_user) AND rated_by = sqlc.arg(rated_by) AND score = 5
    AND include_in_score AND nullified_at IS NULL AND submitted_at >= sqlc.arg(since);

-- name: ListRatings :many
SELECT id, ride_id, rated_by, rated_user, score, reason_tags, comment, include_in_score, exclusion_reason, nullified_at, submitted_at
FROM ride_ratings
WHERE (sqlc.narg(rated_user)::uuid IS NULL OR rated_user = sqlc.narg(rated_user))
    AND (NOT sqlc.arg(excluded_only)::boolean OR NOT include_in_score)
ORDER BY submitted_at DESC, id
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: GetRatingForUpdate :one
SELECT id, ride_id, rated_user, score, reason_tags, nullified_at FROM ride_ratings WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: NullifyRating :exec
UPDATE ride_ratings
SET include_in_score = false, exclusion_reason = 'ops_nullified', nullified_at = sqlc.arg(now),
    nullified_by = sqlc.arg(actor), nullification_reason = sqlc.arg(reason)
WHERE id = sqlc.arg(id);

-- name: ReinstateRating :exec
UPDATE ride_ratings
SET include_in_score = sqlc.arg(include_in_score), exclusion_reason = sqlc.arg(exclusion_reason),
    nullified_at = NULL, nullified_by = NULL, nullification_reason = NULL
WHERE id = sqlc.arg(id);

-- name: GetUserRoles :many
SELECT role FROM user_roles WHERE user_id = sqlc.arg(user_id) AND revoked_at IS NULL;
