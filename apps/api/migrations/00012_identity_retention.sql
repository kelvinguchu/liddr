-- +goose Up
-- Email and Google accounts have no phone until the person adds one.
ALTER TABLE users ALTER COLUMN phone DROP NOT NULL;
-- email is sensitive. Removed with the account.
ALTER TABLE users ADD COLUMN email text UNIQUE CHECK (email = lower(email));

CREATE TABLE auth_identities (
    provider text NOT NULL CHECK (provider IN ('google')),
    subject text NOT NULL,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL,
    last_used_at timestamptz NOT NULL,
    PRIMARY KEY (provider, subject)
);

CREATE INDEX auth_identities_user ON auth_identities (user_id);

-- Rows can be deleted seven days after expiry.
CREATE TABLE email_challenges (
    id uuid PRIMARY KEY,
    email text NOT NULL,
    code_hash bytea NOT NULL,
    ip_hash bytea NOT NULL,
    attempts integer NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    closed_at timestamptz,
    delivery_failed_at timestamptz,
    created_at timestamptz NOT NULL
);

CREATE INDEX email_challenges_email_created ON email_challenges (email, created_at DESC);
CREATE INDEX email_challenges_ip_created ON email_challenges (ip_hash, created_at DESC);

CREATE INDEX auth_challenges_expiry ON auth_challenges (expires_at);
CREATE INDEX email_challenges_expiry ON email_challenges (expires_at);
CREATE INDEX auth_sessions_refresh_expiry ON auth_sessions (refresh_expires_at);
CREATE INDEX audit_events_created ON audit_events (created_at);
CREATE INDEX notifications_created ON notifications (created_at);
CREATE INDEX ride_quotes_created ON ride_quotes (created_at);
CREATE INDEX verification_uploads_expiry ON verification_uploads (expires_at) WHERE consumed_at IS NULL;
CREATE INDEX send_proof_uploads_expiry ON send_proof_uploads (expires_at) WHERE consumed_at IS NULL;
CREATE INDEX mpesa_unmatched_received ON mpesa_unmatched_callbacks (received_at);
