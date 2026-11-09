-- name: InsertSystemAuditEvent :exec
INSERT INTO audit_events (action, user_id, request_id, ip, created_at)
VALUES (sqlc.arg(action), sqlc.arg(user_id), 'system', '0.0.0.0', sqlc.arg(created_at));

-- name: GetDriverForPayment :one
SELECT d.user_id, d.verification_status, d.vehicle_category_id, c.weekly_subscription_kes, COALESCE(u.phone, '')::text AS phone
FROM drivers AS d
JOIN vehicle_categories AS c ON c.id = d.vehicle_category_id
JOIN users AS u ON u.id = d.user_id
WHERE d.user_id = sqlc.arg(user_id)
FOR UPDATE OF d;

-- name: LockDriverRow :exec
SELECT user_id FROM drivers WHERE user_id = sqlc.arg(user_id) FOR UPDATE;

-- name: InsertSubscriptionIfAbsent :exec
INSERT INTO subscriptions (
    id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, created_at
) VALUES (
    sqlc.arg(id), sqlc.arg(driver_id), sqlc.arg(vehicle_category_id), sqlc.arg(week_start),
    sqlc.arg(week_end), sqlc.arg(amount_kes), 'pending', sqlc.arg(reference), sqlc.arg(created_at)
)
ON CONFLICT (driver_id, week_start) DO NOTHING;

-- name: GetSubscriptionForWeek :one
SELECT id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, activated_at, expired_at, created_at
FROM subscriptions
WHERE driver_id = sqlc.arg(driver_id) AND week_start = sqlc.arg(week_start)
FOR UPDATE;

-- name: SyncPendingSubscription :exec
UPDATE subscriptions
SET amount_kes = sqlc.arg(amount_kes), vehicle_category_id = sqlc.arg(vehicle_category_id)
WHERE id = sqlc.arg(id) AND status = 'pending';

-- name: GetSubscriptionByIDForUpdate :one
SELECT id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, activated_at, expired_at, created_at
FROM subscriptions WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: GetSubscriptionByReference :one
SELECT id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, activated_at, expired_at, created_at
FROM subscriptions WHERE reference = sqlc.arg(reference);

-- name: CountRecentPayments :one
SELECT count(*) FROM subscription_payments
WHERE driver_id = sqlc.arg(driver_id) AND channel = 'stk' AND requested_at > sqlc.arg(since);

-- name: InsertSTKPayment :execrows
INSERT INTO subscription_payments (id, subscription_id, driver_id, channel, status, amount_kes, phone, requested_at)
VALUES (
    sqlc.arg(id), sqlc.arg(subscription_id), sqlc.arg(driver_id), 'stk', 'initiated',
    sqlc.arg(amount_kes), sqlc.arg(phone), sqlc.arg(requested_at)
)
ON CONFLICT DO NOTHING;

-- name: MarkPaymentPendingCallback :exec
UPDATE subscription_payments
SET status = 'pending_callback', merchant_request_id = sqlc.arg(merchant_request_id),
    checkout_request_id = sqlc.arg(checkout_request_id)
WHERE id = sqlc.arg(id) AND status = 'initiated';

-- name: MarkPaymentRejected :exec
UPDATE subscription_payments
SET status = 'failed', result_desc = sqlc.arg(result_desc)
WHERE id = sqlc.arg(id) AND status = 'initiated';

-- name: GetPaymentByCheckoutForUpdate :one
SELECT id, subscription_id, driver_id, status, amount_kes, phone
FROM subscription_payments
WHERE checkout_request_id = sqlc.arg(checkout_request_id)
FOR UPDATE;

-- name: GetPaymentForUpdate :one
SELECT id, subscription_id, driver_id, status, amount_kes, phone
FROM subscription_payments
WHERE id = sqlc.arg(id)
FOR UPDATE;

-- name: SetPaymentResult :exec
UPDATE subscription_payments
SET status = sqlc.arg(status), result_code = sqlc.arg(result_code), result_desc = sqlc.arg(result_desc),
    receipt = COALESCE(sqlc.narg(receipt), receipt), paid_at = COALESCE(sqlc.narg(paid_at), paid_at)
WHERE id = sqlc.arg(id);

-- name: MovePaymentToSubscription :exec
UPDATE subscription_payments SET subscription_id = sqlc.arg(subscription_id) WHERE id = sqlc.arg(id);

-- name: ActivateSubscription :exec
UPDATE subscriptions
SET status = 'active', activated_at = COALESCE(activated_at, sqlc.arg(now))
WHERE id = sqlc.arg(id);

-- name: SetDriverSubscriptionActive :exec
UPDATE drivers SET subscription_status = 'active', updated_at = now() WHERE user_id = sqlc.arg(user_id);

-- name: InsertC2BPayment :execrows
INSERT INTO subscription_payments (
    id, subscription_id, driver_id, channel, status, amount_kes, phone, receipt, result_code,
    result_desc, requested_at, paid_at
) VALUES (
    sqlc.arg(id), sqlc.arg(subscription_id), sqlc.arg(driver_id), 'c2b', 'success', sqlc.arg(amount_kes),
    sqlc.narg(phone), sqlc.arg(receipt), 0, 'C2B confirmation received', sqlc.arg(now), sqlc.arg(now)
)
ON CONFLICT (receipt) DO NOTHING;

-- name: InsertUnmatchedCallback :exec
INSERT INTO mpesa_unmatched_callbacks (kind, external_ref, amount_kes, account_reference, reason, received_at)
VALUES (
    sqlc.arg(kind), sqlc.arg(external_ref), sqlc.narg(amount_kes), sqlc.narg(account_reference),
    sqlc.arg(reason), sqlc.arg(received_at)
)
ON CONFLICT (kind, external_ref) DO NOTHING;

-- name: ClaimPaymentsToReconcile :many
UPDATE subscription_payments
SET last_checked_at = sqlc.arg(now)
WHERE id IN (
    SELECT p.id FROM subscription_payments AS p
    WHERE p.status IN ('initiated', 'pending_callback')
        AND p.requested_at <= sqlc.arg(requested_before)
        AND (p.last_checked_at IS NULL OR p.last_checked_at <= sqlc.arg(checked_before))
    ORDER BY p.requested_at
    LIMIT sqlc.arg(batch)
    FOR UPDATE SKIP LOCKED
)
RETURNING id, checkout_request_id, requested_at;

-- name: ExpireLapsedSubscriptions :exec
UPDATE subscriptions SET status = 'expired', expired_at = sqlc.arg(now)
WHERE status = 'active' AND week_end < sqlc.arg(today);

-- name: DowngradeUnpaidDrivers :exec
UPDATE drivers AS d
SET subscription_status = CASE WHEN sqlc.arg(in_grace)::boolean THEN 'grace' ELSE 'inactive' END,
    is_online = d.is_online AND sqlc.arg(in_grace)::boolean,
    updated_at = now()
WHERE d.subscription_status IN ('active', 'grace')
    AND NOT EXISTS (
        SELECT 1 FROM subscriptions AS s
        WHERE s.driver_id = d.user_id AND s.status = 'active'
            AND s.week_start <= sqlc.arg(today) AND s.week_end >= sqlc.arg(today)
    );

-- name: ListDriverPayments :many
SELECT id, channel, status, amount_kes, receipt, requested_at, paid_at
FROM subscription_payments
WHERE driver_id = sqlc.arg(driver_id)
ORDER BY requested_at DESC
LIMIT 50;

-- name: GetPaymentByCheckout :one
SELECT id, driver_id, channel, status, amount_kes, phone, receipt, requested_at, paid_at, checkout_request_id
FROM subscription_payments
WHERE checkout_request_id = sqlc.arg(checkout_request_id);
