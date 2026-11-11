-- +goose Up
ALTER TABLE rides DROP CONSTRAINT rides_cancelled_by_check;
ALTER TABLE rides ADD CONSTRAINT rides_cancelled_by_check CHECK (cancelled_by IN ('rider', 'driver', 'system'));
ALTER TABLE rides ADD COLUMN pickup_distance_m_at_accept integer;
ALTER TABLE rides ADD COLUMN pickup_eta_s_at_accept integer;
ALTER TABLE rides ADD COLUMN reassign_count integer NOT NULL DEFAULT 0;

CREATE INDEX rides_awaiting_pickup ON rides (accepted_at) WHERE status IN ('accepted', 'driver_arriving');

-- Coordinates are sensitive and kept with the ride record.
CREATE TABLE ride_destination_changes (
    id uuid PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    requested_by uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    driver_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    old_dropoff_lat double precision NOT NULL,
    old_dropoff_lng double precision NOT NULL,
    new_dropoff_lat double precision NOT NULL,
    new_dropoff_lng double precision NOT NULL,
    old_fare_kes integer NOT NULL,
    new_fare_kes integer NOT NULL CHECK (new_fare_kes >= 0),
    status text NOT NULL CHECK (status IN ('requested', 'accepted', 'rejected', 'expired')),
    reason_code text NOT NULL,
    notes text,
    requested_at timestamptz NOT NULL,
    responded_at timestamptz
);

CREATE UNIQUE INDEX ride_destination_changes_one_open ON ride_destination_changes (ride_id) WHERE status = 'requested';
CREATE INDEX ride_destination_changes_ride ON ride_destination_changes (ride_id, requested_at DESC);
