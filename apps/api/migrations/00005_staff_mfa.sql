-- +goose Up
ALTER TABLE auth_challenges DROP CONSTRAINT auth_challenges_requested_role_check;
ALTER TABLE auth_challenges ADD CONSTRAINT auth_challenges_requested_role_check
    CHECK (requested_role IN ('rider', 'driver', 'staff'));

-- secret_sealed and pending_secret_sealed are critical and encrypted by the API.
-- Enrolment lives in pending_* so that starting over can never disturb a
-- working authenticator. Deleted with the account.
CREATE TABLE totp_credentials (
    user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    secret_sealed bytea,
    confirmed_at timestamptz,
    last_counter bigint NOT NULL DEFAULT -1,
    failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
    locked_until timestamptz,
    pending_secret_sealed bytea,
    pending_expires_at timestamptz,
    pending_attempts integer NOT NULL DEFAULT 0 CHECK (pending_attempts >= 0),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CHECK ((secret_sealed IS NULL) = (confirmed_at IS NULL)),
    CHECK ((pending_secret_sealed IS NULL) = (pending_expires_at IS NULL))
);
