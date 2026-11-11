-- +goose Up
ALTER TABLE users ADD COLUMN booking_restricted_until timestamptz;

-- One row per cancellation or no-show, with whether it counted against someone.
-- Kept with the ride record.
CREATE TABLE ride_integrity_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ride_id uuid NOT NULL UNIQUE REFERENCES rides (id) ON DELETE CASCADE,
    subject_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    subject_role text NOT NULL CHECK (subject_role IN ('rider', 'driver')),
    violation_type text NOT NULL CHECK (violation_type IN ('cancellation', 'no_show')),
    reason_code text NOT NULL,
    chargeable boolean NOT NULL,
    waiver_code text,
    occurred_at timestamptz NOT NULL
);

CREATE INDEX ride_integrity_chargeable ON ride_integrity_events (subject_id, subject_role, occurred_at DESC) WHERE chargeable;
