-- +goose Up
-- Enforcements now say what they restrict. Only platform scope affects sign-in.
ALTER TABLE user_enforcements ADD COLUMN scope text NOT NULL DEFAULT 'platform'
    CHECK (scope IN ('platform', 'communication'));

-- body is sensitive and can be deleted 90 days after the ride ends.
CREATE TABLE ride_messages (
    seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id uuid NOT NULL UNIQUE,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    sender_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    recipient_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    sender_role text NOT NULL CHECK (sender_role IN ('rider', 'driver')),
    message_type text NOT NULL CHECK (message_type IN ('text', 'quick_action')),
    quick_action_code text,
    body text NOT NULL CHECK (length(body) BETWEEN 1 AND 1000),
    read_at timestamptz,
    hidden_for_sender_at timestamptz,
    hidden_for_recipient_at timestamptz,
    created_at timestamptz NOT NULL,
    CHECK (sender_id <> recipient_id)
);

CREATE INDEX ride_messages_ride ON ride_messages (ride_id, seq);
CREATE INDEX ride_messages_unread ON ride_messages (ride_id, recipient_id) WHERE read_at IS NULL;
CREATE INDEX ride_messages_sender_created ON ride_messages (sender_id, created_at DESC);

ALTER TABLE reports ADD COLUMN message_id uuid REFERENCES ride_messages (id) ON DELETE SET NULL;
DROP INDEX reports_one_per_ride;
CREATE UNIQUE INDEX reports_one_per_ride ON reports (reporter_id, ride_id, category)
    WHERE dispute_type IS NULL AND ride_id IS NOT NULL AND message_id IS NULL;
CREATE UNIQUE INDEX reports_one_per_message ON reports (reporter_id, message_id) WHERE message_id IS NOT NULL;
CREATE INDEX reports_message_reported ON reports (reported_id, created_at DESC) WHERE message_id IS NOT NULL;

CREATE TABLE prohibited_items (
    keyword text PRIMARY KEY CHECK (keyword = lower(keyword) AND length(keyword) >= 2),
    severity text NOT NULL CHECK (severity IN ('block', 'warn')),
    message text NOT NULL,
    active boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO prohibited_items (keyword, severity, message) VALUES
    ('cash', 'block', 'Cash delivery is not allowed for Send.'),
    ('firearm', 'block', 'Firearms are prohibited on the platform.'),
    ('gun', 'block', 'Firearms are prohibited on the platform.'),
    ('alcohol', 'block', 'Alcohol delivery is not supported for Send.'),
    ('drug', 'block', 'Drugs and medicines cannot be sent.'),
    ('medicine', 'block', 'Drugs and medicines cannot be sent.'),
    ('live animal', 'block', 'Live animals cannot be sent.'),
    ('jewellery', 'warn', 'High-value items travel at sender liability.'),
    ('electronics', 'warn', 'Fragile electronics require careful packaging by sender.'),
    ('food', 'warn', 'Food travels at sender liability.');

-- Names, phones and the item description are sensitive. Proof files are private.
-- Kept with the ride record.
CREATE TABLE send_deliveries (
    ride_id uuid PRIMARY KEY REFERENCES rides (id) ON DELETE CASCADE,
    sender_name text NOT NULL,
    sender_phone text NOT NULL,
    recipient_name text NOT NULL,
    recipient_phone text NOT NULL,
    item_description text NOT NULL,
    item_size text NOT NULL CHECK (item_size IN ('small', 'medium', 'large')),
    payer text NOT NULL CHECK (payer IN ('sender', 'recipient')),
    payment_timing text NOT NULL CHECK (payment_timing IN ('before', 'after')),
    item_value_kes integer CHECK (item_value_kes >= 0),
    special_instructions text,
    liability_acknowledged boolean NOT NULL,
    pickup_proof_key text,
    pickup_proof_at timestamptz,
    dropoff_proof_key text,
    dropoff_proof_at timestamptz,
    recipient_confirmed_at timestamptz,
    delivery_status text NOT NULL CHECK (delivery_status IN (
        'pending_pickup', 'in_transit', 'delivered_pending_confirmation', 'delivered_confirmed', 'completed'
    )),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CHECK (NOT (payer = 'recipient' AND payment_timing = 'before'))
);

CREATE INDEX send_deliveries_recipient ON send_deliveries (recipient_phone);

CREATE TABLE send_proof_uploads (
    id uuid PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    driver_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    proof_kind text NOT NULL CHECK (proof_kind IN ('pickup', 'dropoff')),
    storage_key text NOT NULL UNIQUE,
    content_type text NOT NULL,
    size_bytes bigint NOT NULL CHECK (size_bytes > 0),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL
);

CREATE INDEX send_proof_uploads_driver_created ON send_proof_uploads (driver_id, created_at DESC);
