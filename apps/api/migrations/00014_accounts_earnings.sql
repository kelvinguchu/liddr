-- +goose Up
-- display_name is sensitive. Removed with the account.
ALTER TABLE users ADD COLUMN display_name text CHECK (char_length(display_name) BETWEEN 2 AND 60);
-- deleted_at starts the one-year clock on the account's verification documents.
ALTER TABLE users ADD COLUMN deleted_at timestamptz;

CREATE INDEX rides_driver_completed ON rides (driver_id, completed_at DESC) WHERE status = 'completed';

ALTER TABLE auth_sessions DROP CONSTRAINT auth_sessions_revoked_reason_check;
ALTER TABLE auth_sessions ADD CONSTRAINT auth_sessions_revoked_reason_check CHECK (
    revoked_reason IN ('rotated', 'superseded', 'logout', 'reuse_detected', 'account_blocked', 'account_deleted')
);

-- photo_consent_at is when the driver agreed that riders may see their
-- verification selfie as their photo. Removed with the account.
ALTER TABLE drivers ADD COLUMN photo_consent_at timestamptz;

-- reminded_at makes the renewal reminder go out once per paid week.
ALTER TABLE subscriptions ADD COLUMN reminded_at timestamptz;

-- purged_at records that the file left storage. The row stays as the audit
-- trail of what was reviewed, and holds no document content.
ALTER TABLE verification_documents ADD COLUMN purged_at timestamptz;
