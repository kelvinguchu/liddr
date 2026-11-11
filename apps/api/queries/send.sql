-- name: ListActiveProhibitedItems :many
SELECT keyword, severity, message FROM prohibited_items WHERE active ORDER BY keyword;

-- name: ListProhibitedItems :many
SELECT keyword, severity, message, active FROM prohibited_items ORDER BY keyword;

-- name: UpsertProhibitedItem :exec
INSERT INTO prohibited_items (keyword, severity, message, active, updated_at)
VALUES (sqlc.arg(keyword), sqlc.arg(severity), sqlc.arg(message), sqlc.arg(active), sqlc.arg(now))
ON CONFLICT (keyword) DO UPDATE SET
    severity = EXCLUDED.severity, message = EXCLUDED.message, active = EXCLUDED.active, updated_at = EXCLUDED.updated_at;

-- name: InsertSendDelivery :exec
INSERT INTO send_deliveries (
    ride_id, sender_name, sender_phone, recipient_name, recipient_phone, item_description, item_size, payer,
    payment_timing, item_value_kes, special_instructions, liability_acknowledged, delivery_status, created_at, updated_at
) VALUES (
    sqlc.arg(ride_id), sqlc.arg(sender_name), sqlc.arg(sender_phone), sqlc.arg(recipient_name), sqlc.arg(recipient_phone),
    sqlc.arg(item_description), sqlc.arg(item_size), sqlc.arg(payer), sqlc.arg(payment_timing), sqlc.arg(item_value_kes),
    sqlc.arg(special_instructions), sqlc.arg(liability_acknowledged), 'pending_pickup', sqlc.arg(now), sqlc.arg(now)
)
ON CONFLICT (ride_id) DO NOTHING;

-- name: GetSendDelivery :one
SELECT d.ride_id, d.sender_name, d.sender_phone, d.recipient_name, d.recipient_phone, d.item_description, d.item_size,
    d.payer, d.payment_timing, d.item_value_kes, d.special_instructions, d.liability_acknowledged, d.pickup_proof_at,
    d.dropoff_proof_at, d.recipient_confirmed_at, d.delivery_status, d.pickup_proof_key, d.dropoff_proof_key,
    r.rider_id, r.driver_id, r.status AS ride_status, r.vehicle_category_id
FROM send_deliveries AS d
JOIN rides AS r ON r.id = d.ride_id
WHERE d.ride_id = sqlc.arg(ride_id);

-- name: GetSendDeliveryForRide :one
SELECT pickup_proof_at, dropoff_proof_at, recipient_confirmed_at FROM send_deliveries WHERE ride_id = sqlc.arg(ride_id);

-- name: IsSendRide :one
SELECT EXISTS (SELECT 1 FROM send_deliveries WHERE ride_id = sqlc.arg(ride_id));

-- name: MarkDeliveryCompleted :exec
UPDATE send_deliveries SET delivery_status = 'completed', updated_at = sqlc.arg(now) WHERE ride_id = sqlc.arg(ride_id);

-- name: InsertSendProofUpload :exec
INSERT INTO send_proof_uploads (id, ride_id, driver_id, proof_kind, storage_key, content_type, size_bytes, expires_at, created_at)
VALUES (sqlc.arg(id), sqlc.arg(ride_id), sqlc.arg(driver_id), sqlc.arg(proof_kind), sqlc.arg(storage_key), sqlc.arg(content_type),
    sqlc.arg(size_bytes), sqlc.arg(expires_at), sqlc.arg(now));

-- name: CountRecentSendProofUploads :one
SELECT count(*) FROM send_proof_uploads WHERE driver_id = sqlc.arg(driver_id) AND created_at > sqlc.arg(since);

-- name: GetSendProofUpload :one
SELECT id, ride_id, driver_id, proof_kind, storage_key, content_type, size_bytes, expires_at, consumed_at
FROM send_proof_uploads
WHERE id = sqlc.arg(id) AND driver_id = sqlc.arg(driver_id);

-- name: ConsumeSendProofUpload :execrows
UPDATE send_proof_uploads SET consumed_at = sqlc.arg(now) WHERE id = sqlc.arg(id) AND consumed_at IS NULL;

-- name: RecordPickupProof :exec
UPDATE send_deliveries SET pickup_proof_key = sqlc.arg(key), pickup_proof_at = COALESCE(pickup_proof_at, sqlc.arg(now)), updated_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id);

-- name: RecordDropoffProof :exec
UPDATE send_deliveries
SET dropoff_proof_key = sqlc.arg(key), dropoff_proof_at = sqlc.arg(now), delivery_status = 'delivered_pending_confirmation', updated_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id);

-- name: RecordRecipientConfirmed :exec
UPDATE send_deliveries
SET recipient_confirmed_at = COALESCE(recipient_confirmed_at, sqlc.arg(now)), delivery_status = 'delivered_confirmed', updated_at = sqlc.arg(now)
WHERE ride_id = sqlc.arg(ride_id);

-- name: FindUserIDByPhone :one
SELECT id FROM users WHERE phone = sqlc.arg(phone);

-- name: GetRideDriverAndStatus :one
SELECT id, rider_id, driver_id, status FROM rides WHERE id = sqlc.arg(id) FOR UPDATE;

-- name: IsSendQuote :one
SELECT c.slug = 'send' FROM ride_quotes AS q JOIN vehicle_categories AS c ON c.id = q.vehicle_category_id WHERE q.id = sqlc.arg(id);
