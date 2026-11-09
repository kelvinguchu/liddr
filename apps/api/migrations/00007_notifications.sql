-- +goose Up
-- The durable inbox behind live updates. Holds identifiers only, never places
-- or message text. Rows can be deleted 30 days after created_at.
CREATE TABLE notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    event_type text NOT NULL,
    ride_id uuid,
    offer_id uuid,
    status text,
    push_status text NOT NULL DEFAULT 'pending'
        CHECK (push_status IN ('pending', 'sent', 'no_device', 'failed', 'expired')),
    push_attempts integer NOT NULL DEFAULT 0,
    push_claimed_until timestamptz,
    acked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX notifications_user_created ON notifications (user_id, created_at DESC);
CREATE INDEX notifications_user_unacked ON notifications (user_id) WHERE acked_at IS NULL;
CREATE INDEX notifications_push_queue ON notifications (created_at) WHERE push_status = 'pending';

-- token is sensitive: it can address this person's phone. family_id ties it to
-- the sign-in that registered it, so signing out stops the pushes.
CREATE TABLE push_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    family_id uuid NOT NULL,
    token text NOT NULL UNIQUE,
    platform text NOT NULL CHECK (platform IN ('android', 'ios')),
    last_seen_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL
);

CREATE INDEX push_tokens_user_active ON push_tokens (user_id, last_seen_at DESC) WHERE revoked_at IS NULL;
CREATE INDEX push_tokens_family ON push_tokens (family_id) WHERE revoked_at IS NULL;
