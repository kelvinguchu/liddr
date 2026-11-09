-- +goose Up
ALTER TABLE ride_quotes ADD COLUMN product_type text NOT NULL DEFAULT 'solo' CHECK (product_type IN ('solo', 'shared'));
ALTER TABLE ride_quotes ADD COLUMN solo_fare_kes integer CHECK (solo_fare_kes >= 0);
ALTER TABLE rides ADD COLUMN product_type text NOT NULL DEFAULT 'solo' CHECK (product_type IN ('solo', 'shared'));

CREATE INDEX rides_shared_open ON rides (vehicle_category_id, requested_at DESC)
    WHERE product_type = 'shared' AND status = 'searching';

-- A strike belongs to a person on a ride. A shared ride can have several.
ALTER TABLE ride_integrity_events DROP CONSTRAINT ride_integrity_events_ride_id_key;
ALTER TABLE ride_integrity_events ADD CONSTRAINT ride_integrity_events_ride_subject_key UNIQUE (ride_id, subject_id);

-- One row per passenger. Coordinates are sensitive and kept with the ride.
CREATE TABLE shared_members (
    id uuid PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    rider_id uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    quote_id uuid NOT NULL UNIQUE REFERENCES ride_quotes (id) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN (
        'requested', 'assigned', 'pickup_pending', 'picked_up', 'dropped_off', 'cancelled', 'no_show'
    )),
    fare_kes integer NOT NULL CHECK (fare_kes >= 0),
    pickup_lat double precision NOT NULL,
    pickup_lng double precision NOT NULL,
    dropoff_lat double precision NOT NULL,
    dropoff_lng double precision NOT NULL,
    requested_at timestamptz NOT NULL,
    pickup_arrived_at timestamptz,
    picked_up_at timestamptz,
    dropped_off_at timestamptz,
    ended_at timestamptz,
    UNIQUE (ride_id, rider_id)
);

CREATE INDEX shared_members_ride ON shared_members (ride_id);
CREATE UNIQUE INDEX shared_members_one_active ON shared_members (rider_id)
    WHERE status IN ('requested', 'assigned', 'pickup_pending', 'picked_up');
