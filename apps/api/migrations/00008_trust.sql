-- +goose Up
CREATE TABLE report_categories (
    slug text PRIMARY KEY,
    label text NOT NULL,
    applies_to text NOT NULL CHECK (applies_to IN ('driver', 'both')),
    default_severity integer NOT NULL CHECK (default_severity BETWEEN 1 AND 5),
    active boolean NOT NULL DEFAULT true,
    display_order integer NOT NULL
);

INSERT INTO report_categories (slug, label, applies_to, default_severity, display_order) VALUES
    ('unsafe_driving', 'Unsafe Driving', 'driver', 5, 10),
    ('harassment_or_abuse', 'Harassment or Abuse', 'both', 5, 20),
    ('sexual_misconduct', 'Sexual Misconduct', 'both', 5, 30),
    ('discrimination', 'Discrimination', 'both', 5, 40),
    ('violence_or_threat', 'Violence or Threat', 'both', 5, 50),
    ('fraud_or_scam', 'Fraud or Scam', 'both', 4, 60),
    ('payment_dispute', 'Payment Dispute', 'both', 3, 70),
    ('account_sharing_or_impersonation', 'Account Sharing or Impersonation', 'both', 4, 80),
    ('vehicle_condition_issue', 'Vehicle Condition Issue', 'driver', 3, 90),
    ('document_or_eligibility_issue', 'Document or Eligibility Issue', 'driver', 4, 100),
    ('intoxication_or_substance_use', 'Intoxication or Substance Use', 'both', 5, 110),
    ('cancellation_or_no_show_abuse', 'Cancellation or No-show Abuse', 'both', 2, 120),
    ('privacy_violation', 'Privacy Violation', 'both', 4, 130),
    ('property_damage', 'Property Damage', 'both', 3, 140),
    ('theft_or_lost_property_misconduct', 'Theft or Lost Property Misconduct', 'both', 4, 150),
    ('child_safety_violation', 'Child Safety Violation', 'both', 5, 160),
    ('off_platform_solicitation', 'Off-platform Solicitation', 'both', 3, 170),
    ('rating_quality_risk', 'Rating Quality Risk', 'both', 3, 900),
    ('rating_manipulation_risk', 'Rating Manipulation Risk', 'both', 3, 910),
    ('other', 'Other', 'both', 2, 990);

-- description is sensitive report text, and is never shown to reported_id.
-- A null reporter_id means the system raised it. Dispute records are kept for
-- three years; other reports can be deleted two years after resolution.
CREATE TABLE reports (
    id uuid PRIMARY KEY,
    reporter_id uuid REFERENCES users (id) ON DELETE SET NULL,
    reported_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    category text NOT NULL REFERENCES report_categories (slug) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN ('submitted', 'triaged', 'under_review', 'resolved', 'dismissed')),
    severity integer NOT NULL CHECK (severity BETWEEN 1 AND 5),
    source text NOT NULL CHECK (source IN ('in_app', 'system')),
    incident_type text NOT NULL CHECK (incident_type IN ('safety', 'conduct', 'fraud', 'payment', 'vehicle', 'account', 'other')),
    ride_id uuid REFERENCES rides (id) ON DELETE SET NULL,
    signal_key text,
    dispute_type text,
    requested_resolution text,
    description text NOT NULL,
    assigned_reviewer_id uuid REFERENCES users (id) ON DELETE SET NULL,
    triaged_at timestamptz,
    resolved_at timestamptz,
    resolution_outcome text,
    resolution_summary text,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CHECK (reporter_id IS NULL OR reporter_id <> reported_id)
);

CREATE INDEX reports_queue ON reports (status, severity DESC, created_at);
CREATE INDEX reports_reporter_created ON reports (reporter_id, created_at DESC);
CREATE INDEX reports_reported ON reports (reported_id, created_at DESC);
CREATE INDEX reports_signal ON reports (reported_id, signal_key, created_at DESC) WHERE signal_key IS NOT NULL;
CREATE UNIQUE INDEX reports_one_per_ride ON reports (reporter_id, ride_id, category)
    WHERE dispute_type IS NULL AND ride_id IS NOT NULL;

CREATE TABLE report_reviews (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_id uuid NOT NULL REFERENCES reports (id) ON DELETE CASCADE,
    reviewer_id uuid REFERENCES users (id) ON DELETE SET NULL,
    decision text NOT NULL,
    status_before text NOT NULL,
    status_after text NOT NULL,
    reason_code text,
    notes text,
    created_at timestamptz NOT NULL
);

CREATE INDEX report_reviews_report ON report_reviews (report_id);

CREATE TABLE user_enforcements (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    report_id uuid REFERENCES reports (id) ON DELETE SET NULL,
    actor_id uuid REFERENCES users (id) ON DELETE SET NULL,
    action text NOT NULL CHECK (action IN ('warning', 'feature_restriction', 'temporary_suspension', 'permanent_ban')),
    status text NOT NULL CHECK (status IN ('active', 'expired', 'lifted')),
    reason_code text NOT NULL,
    reason_text text,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz,
    lifted_at timestamptz,
    lifted_by uuid REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL,
    CHECK ((action = 'temporary_suspension') = (ends_at IS NOT NULL))
);

CREATE INDEX user_enforcements_user_active ON user_enforcements (user_id) WHERE status = 'active';
CREATE INDEX user_enforcements_due ON user_enforcements (ends_at) WHERE status = 'active' AND ends_at IS NOT NULL;
CREATE INDEX user_enforcements_listing ON user_enforcements (status, created_at DESC);

-- Amounts are whole shillings. Kept three years with the dispute.
CREATE TABLE dispute_compensations (
    id uuid PRIMARY KEY,
    report_id uuid NOT NULL UNIQUE REFERENCES reports (id) ON DELETE RESTRICT,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE RESTRICT,
    beneficiary_id uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    counterparty_id uuid REFERENCES users (id) ON DELETE SET NULL,
    actor_id uuid REFERENCES users (id) ON DELETE SET NULL,
    compensation_type text NOT NULL CHECK (compensation_type IN ('refund_full', 'refund_partial', 'credit_note')),
    status text NOT NULL CHECK (status IN ('approved', 'paid', 'cancelled')),
    amount_kes integer NOT NULL CHECK (amount_kes > 0),
    reason_text text,
    processing_channel text CHECK (processing_channel IN ('manual_ops', 'mpesa_reversal', 'wallet_credit', 'bank_transfer')),
    processing_reference text,
    processed_at timestamptz,
    processed_by uuid REFERENCES users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL,
    CHECK (status <> 'paid' OR processing_reference IS NOT NULL)
);

CREATE INDEX dispute_compensations_beneficiary ON dispute_compensations (beneficiary_id, created_at DESC);
CREATE INDEX dispute_compensations_status ON dispute_compensations (status, created_at DESC);

ALTER TABLE users ADD COLUMN rating_centi integer;
ALTER TABLE users ADD COLUMN rating_count integer NOT NULL DEFAULT 0;

-- comment is sensitive and never shown to the person rated.
CREATE TABLE ride_ratings (
    id uuid PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    rated_by uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    rated_user uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    score integer NOT NULL CHECK (score BETWEEN 1 AND 5),
    reason_tags text[] NOT NULL DEFAULT '{}',
    comment text,
    include_in_score boolean NOT NULL,
    exclusion_reason text,
    nullified_at timestamptz,
    nullified_by uuid REFERENCES users (id) ON DELETE SET NULL,
    nullification_reason text,
    submitted_at timestamptz NOT NULL,
    UNIQUE (ride_id, rated_by),
    CHECK (rated_by <> rated_user)
);

CREATE INDEX ride_ratings_rated_user ON ride_ratings (rated_user, submitted_at DESC);
CREATE INDEX ride_ratings_excluded ON ride_ratings (submitted_at DESC) WHERE NOT include_in_score;

CREATE TABLE rating_actions (
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    rated_by uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    rated_user uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    rater_role text NOT NULL CHECK (rater_role IN ('rider', 'driver')),
    status text NOT NULL CHECK (status IN ('pending', 'rated', 'skipped')),
    due_at timestamptz NOT NULL,
    resolved_at timestamptz,
    PRIMARY KEY (ride_id, rated_by)
);

CREATE INDEX rating_actions_pending ON rating_actions (rated_by, due_at) WHERE status = 'pending';
