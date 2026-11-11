-- +goose Up
ALTER TABLE drivers DROP CONSTRAINT drivers_verification_status_check;
ALTER TABLE drivers ADD CONSTRAINT drivers_verification_status_check
    CHECK (verification_status IN ('pending', 'under_review', 'approved', 'rejected', 'suspended'));
-- plate_number is sensitive. Removed with the account.
ALTER TABLE drivers ADD COLUMN plate_number text;

CREATE TABLE verification_requirements (
    document_type text PRIMARY KEY,
    label text NOT NULL,
    required boolean NOT NULL,
    requires_expiry boolean NOT NULL,
    active boolean NOT NULL DEFAULT true,
    display_order integer NOT NULL
);

INSERT INTO verification_requirements (document_type, label, required, requires_expiry, display_order) VALUES
    ('national_id_front', 'National ID (Front)', true, false, 10),
    ('national_id_back', 'National ID (Back)', true, false, 20),
    ('drivers_licence', 'Driver''s Licence', true, true, 30),
    ('psv_badge', 'PSV Badge', true, true, 40),
    ('good_conduct_certificate', 'Good Conduct Certificate', true, true, 50),
    ('vehicle_logbook', 'Vehicle Logbook', true, false, 60),
    ('commercial_insurance', 'Commercial Insurance Certificate', true, true, 70),
    ('vehicle_photo_front', 'Vehicle Photo (Front)', true, false, 80),
    ('vehicle_photo_back', 'Vehicle Photo (Back)', true, false, 90),
    ('vehicle_photo_side', 'Vehicle Photo (Side)', true, false, 100),
    ('driver_selfie_liveness', 'Driver Selfie (Liveness)', true, false, 110);

CREATE TABLE verification_applications (
    id uuid PRIMARY KEY,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE CASCADE,
    status text NOT NULL CHECK (
        status IN ('pending', 'under_review', 'approved', 'rejected', 'resubmission_required', 'suspended')
    ),
    decided_at timestamptz,
    decision_reason text,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX verification_applications_one_open ON verification_applications (driver_id)
    WHERE status IN ('pending', 'under_review', 'resubmission_required');
CREATE INDEX verification_applications_queue ON verification_applications (status, created_at);
CREATE INDEX verification_applications_driver ON verification_applications (driver_id, created_at DESC);

-- A row is issued for each signed upload URL, so a document can only ever be
-- built from an object this server told this driver to upload.
CREATE TABLE verification_uploads (
    id uuid PRIMARY KEY,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE CASCADE,
    document_type text NOT NULL REFERENCES verification_requirements (document_type) ON DELETE RESTRICT,
    storage_key text NOT NULL UNIQUE,
    content_type text NOT NULL,
    size_bytes bigint NOT NULL CHECK (size_bytes > 0),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL
);

CREATE INDEX verification_uploads_driver_created ON verification_uploads (driver_id, created_at DESC);

-- The files behind storage_key are critical data, kept in a private bucket.
-- Kept for as long as the driver account exists.
CREATE TABLE verification_documents (
    id uuid PRIMARY KEY,
    application_id uuid NOT NULL REFERENCES verification_applications (id) ON DELETE CASCADE,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE CASCADE,
    document_type text NOT NULL REFERENCES verification_requirements (document_type) ON DELETE RESTRICT,
    version integer NOT NULL CHECK (version >= 1),
    status text NOT NULL CHECK (
        status IN ('scanning', 'pending_review', 'validated', 'rejected', 'expired', 'resubmission_required', 'superseded')
    ),
    storage_key text NOT NULL UNIQUE,
    content_type text NOT NULL,
    size_bytes bigint NOT NULL CHECK (size_bytes > 0),
    expires_on date,
    rejection_reason text,
    scan_status text NOT NULL CHECK (scan_status IN ('pending', 'clean', 'infected', 'failed')),
    scan_signature text,
    scan_attempts integer NOT NULL DEFAULT 0,
    scan_claimed_until timestamptz,
    scanned_at timestamptz,
    reviewed_at timestamptz,
    reviewed_by uuid REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    UNIQUE (driver_id, document_type, version)
);

CREATE UNIQUE INDEX verification_documents_one_live ON verification_documents (driver_id, document_type)
    WHERE status <> 'superseded';
CREATE INDEX verification_documents_application ON verification_documents (application_id);
CREATE INDEX verification_documents_scan_queue ON verification_documents (created_at) WHERE scan_status = 'pending';
CREATE INDEX verification_documents_expiry ON verification_documents (expires_on)
    WHERE expires_on IS NOT NULL AND status <> 'superseded';

-- Every decision, with its actor and the state before and after. A null
-- reviewer_id means the system decided.
CREATE TABLE verification_reviews (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id uuid NOT NULL REFERENCES verification_applications (id) ON DELETE CASCADE,
    document_id uuid REFERENCES verification_documents (id) ON DELETE CASCADE,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE CASCADE,
    reviewer_id uuid REFERENCES users (id) ON DELETE SET NULL,
    decision text NOT NULL,
    status_before text NOT NULL,
    status_after text NOT NULL,
    reason text,
    created_at timestamptz NOT NULL
);

CREATE INDEX verification_reviews_application ON verification_reviews (application_id);

ALTER TABLE audit_events ADD COLUMN target text;
