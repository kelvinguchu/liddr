-- +goose Up
-- One row per driver and week. Weeks run Monday to Sunday, Nairobi time.
CREATE TABLE subscriptions (
    id uuid PRIMARY KEY,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE RESTRICT,
    vehicle_category_id bigint NOT NULL REFERENCES vehicle_categories (id) ON DELETE RESTRICT,
    week_start date NOT NULL,
    week_end date NOT NULL,
    amount_kes integer NOT NULL CHECK (amount_kes > 0),
    status text NOT NULL CHECK (status IN ('pending', 'active', 'expired')),
    -- The account number a driver enters to pay by paybill. Daraja allows 12 characters.
    reference text NOT NULL UNIQUE CHECK (char_length(reference) <= 12),
    activated_at timestamptz,
    expired_at timestamptz,
    created_at timestamptz NOT NULL,
    UNIQUE (driver_id, week_start),
    CHECK (week_end > week_start)
);

CREATE INDEX subscriptions_active_expiry ON subscriptions (week_end) WHERE status = 'active';

-- phone and the provider identifiers are payment identifiers. Payment records
-- are kept for seven years.
CREATE TABLE subscription_payments (
    id uuid PRIMARY KEY,
    subscription_id uuid NOT NULL REFERENCES subscriptions (id) ON DELETE RESTRICT,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE RESTRICT,
    channel text NOT NULL CHECK (channel IN ('stk', 'c2b')),
    status text NOT NULL CHECK (status IN (
        'initiated', 'pending_callback', 'success', 'failed', 'cancelled', 'timeout', 'needs_review'
    )),
    amount_kes integer NOT NULL CHECK (amount_kes > 0),
    phone text,
    merchant_request_id text,
    checkout_request_id text UNIQUE,
    receipt text UNIQUE,
    result_code integer,
    result_desc text,
    requested_at timestamptz NOT NULL,
    paid_at timestamptz,
    last_checked_at timestamptz
);

-- At most one STK prompt can be outstanding for a subscription.
CREATE UNIQUE INDEX subscription_payments_one_pending ON subscription_payments (subscription_id)
    WHERE status IN ('initiated', 'pending_callback');
CREATE INDEX subscription_payments_driver ON subscription_payments (driver_id, requested_at DESC);
CREATE INDEX subscription_payments_pending ON subscription_payments (requested_at)
    WHERE status IN ('initiated', 'pending_callback');

-- Money that arrived but could not be applied, kept for operations to resolve.
-- Holds no phone number. Kept for seven years with the payment records.
CREATE TABLE mpesa_unmatched_callbacks (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('stk', 'c2b')),
    external_ref text NOT NULL,
    amount_kes integer,
    account_reference text,
    reason text NOT NULL,
    received_at timestamptz NOT NULL,
    UNIQUE (kind, external_ref)
);
