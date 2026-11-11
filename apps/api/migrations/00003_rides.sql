-- +goose Up
-- Money is integer cents, and percentages are basis points, so that fares never
-- pass through floating point.
ALTER TABLE vehicle_categories
    ADD COLUMN base_fee_cents bigint NOT NULL DEFAULT 0 CHECK (base_fee_cents >= 0),
    ADD COLUMN price_per_km_cents bigint NOT NULL DEFAULT 0 CHECK (price_per_km_cents >= 0),
    ADD COLUMN price_per_min_cents bigint NOT NULL DEFAULT 0 CHECK (price_per_min_cents >= 0),
    ADD COLUMN min_fare_cents bigint NOT NULL DEFAULT 0 CHECK (min_fare_cents >= 0),
    ADD COLUMN discount_bps integer NOT NULL DEFAULT 0 CHECK (discount_bps BETWEEN 0 AND 10000),
    ADD COLUMN search_radius_m integer NOT NULL DEFAULT 6000 CHECK (search_radius_m > 0);

UPDATE vehicle_categories AS category
SET base_fee_cents = rates.base * 100,
    price_per_km_cents = rates.per_km * 100,
    price_per_min_cents = rates.per_min * 100,
    min_fare_cents = rates.minimum * 100,
    discount_bps = 1500,
    search_radius_m = rates.radius
FROM (VALUES
    ('motorbike', 20, 15, 3, 120, 3500),
    ('electric_motorbike', 45, 15, 3, 140, 4000),
    ('basic', 55, 25, 5, 230, 6000),
    ('send', 25, 16, 3, 150, 4000),
    ('comfort', 95, 42, 11, 390, 7000),
    ('xl', 140, 40, 16, 470, 8000),
    ('women_only', 62, 32, 6, 300, 6000),
    ('green', 60, 31, 6, 290, 6000)
) AS rates (slug, base, per_km, per_min, minimum, radius)
WHERE category.slug = rates.slug;

CREATE TABLE drivers (
    user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    vehicle_category_id bigint NOT NULL REFERENCES vehicle_categories (id) ON DELETE RESTRICT,
    verification_status text NOT NULL DEFAULT 'pending'
        CHECK (verification_status IN ('pending', 'approved', 'rejected')),
    subscription_status text NOT NULL DEFAULT 'inactive'
        CHECK (subscription_status IN ('inactive', 'active', 'grace', 'suspended')),
    is_online boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Live location is sensitive. One row per driver, overwritten on every ping.
CREATE TABLE driver_locations (
    driver_id uuid PRIMARY KEY REFERENCES drivers (user_id) ON DELETE CASCADE,
    lat double precision NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng double precision NOT NULL CHECK (lng BETWEEN -180 AND 180),
    captured_at timestamptz NOT NULL
);

CREATE INDEX driver_locations_position ON driver_locations (lat, lng);

-- Exact pickup and dropoff are sensitive. Rows can be deleted 30 days after
-- created_at, except those referenced by a ride.
CREATE TABLE ride_quotes (
    id uuid PRIMARY KEY,
    rider_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    vehicle_category_id bigint NOT NULL REFERENCES vehicle_categories (id) ON DELETE RESTRICT,
    pickup_lat double precision NOT NULL,
    pickup_lng double precision NOT NULL,
    dropoff_lat double precision NOT NULL,
    dropoff_lng double precision NOT NULL,
    distance_m integer NOT NULL CHECK (distance_m >= 0),
    duration_s integer NOT NULL CHECK (duration_s >= 0),
    polyline text NOT NULL,
    surge_bps integer NOT NULL CHECK (surge_bps BETWEEN 10000 AND 50000),
    subtotal_cents bigint NOT NULL CHECK (subtotal_cents >= 0),
    base_fare_kes integer NOT NULL CHECK (base_fare_kes >= 0),
    discount_kes integer NOT NULL CHECK (discount_kes >= 0),
    final_fare_kes integer NOT NULL CHECK (final_fare_kes >= 0),
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL
);

CREATE INDEX ride_quotes_rider_created ON ride_quotes (rider_id, created_at DESC);

-- Exact pickup and dropoff are sensitive. Ride records are kept for five years.
CREATE TABLE rides (
    id uuid PRIMARY KEY,
    rider_id uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
    driver_id uuid REFERENCES drivers (user_id) ON DELETE RESTRICT,
    quote_id uuid NOT NULL UNIQUE REFERENCES ride_quotes (id) ON DELETE RESTRICT,
    vehicle_category_id bigint NOT NULL REFERENCES vehicle_categories (id) ON DELETE RESTRICT,
    status text NOT NULL CHECK (status IN (
        'searching', 'accepted', 'driver_arriving', 'arrived', 'in_progress',
        'completed', 'cancelled', 'no_drivers'
    )),
    pickup_lat double precision NOT NULL,
    pickup_lng double precision NOT NULL,
    dropoff_lat double precision NOT NULL,
    dropoff_lng double precision NOT NULL,
    fare_kes integer NOT NULL CHECK (fare_kes >= 0),
    payment_mode text CHECK (payment_mode IN ('cash_direct', 'mpesa_direct')),
    search_expires_at timestamptz NOT NULL,
    next_dispatch_at timestamptz,
    dispatch_wave integer NOT NULL DEFAULT 0,
    requested_at timestamptz NOT NULL,
    accepted_at timestamptz,
    arriving_at timestamptz,
    arrived_at timestamptz,
    started_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,
    cancelled_by text CHECK (cancelled_by IN ('rider', 'driver')),
    cancel_reason text,
    arrival_distance_m integer,
    completion_distance_m integer,
    CHECK (status IN ('searching', 'cancelled', 'no_drivers') OR driver_id IS NOT NULL)
);

CREATE UNIQUE INDEX rides_one_active_per_rider ON rides (rider_id)
    WHERE status IN ('searching', 'accepted', 'driver_arriving', 'arrived', 'in_progress');
CREATE UNIQUE INDEX rides_one_active_per_driver ON rides (driver_id)
    WHERE status IN ('accepted', 'driver_arriving', 'arrived', 'in_progress');
CREATE INDEX rides_dispatch_due ON rides (next_dispatch_at) WHERE next_dispatch_at IS NOT NULL;
CREATE INDEX rides_rider_requested ON rides (rider_id, requested_at DESC);
CREATE INDEX rides_demand ON rides (vehicle_category_id, pickup_lat, pickup_lng)
    WHERE status = 'searching';

CREATE TABLE ride_offers (
    id uuid PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    driver_id uuid NOT NULL REFERENCES drivers (user_id) ON DELETE CASCADE,
    status text NOT NULL CHECK (status IN ('offered', 'accepted', 'rejected', 'expired', 'withdrawn')),
    distance_m integer NOT NULL CHECK (distance_m >= 0),
    offered_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    responded_at timestamptz,
    UNIQUE (ride_id, driver_id)
);

-- A driver can hold one open offer, enforced here rather than with a cache lock.
CREATE UNIQUE INDEX ride_offers_one_open_per_driver ON ride_offers (driver_id) WHERE status = 'offered';
CREATE INDEX ride_offers_ride_open ON ride_offers (ride_id) WHERE status = 'offered';

-- Every status change, with actor, before and after.
CREATE TABLE ride_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ride_id uuid NOT NULL REFERENCES rides (id) ON DELETE CASCADE,
    from_status text,
    to_status text NOT NULL,
    actor_user_id uuid REFERENCES users (id) ON DELETE SET NULL,
    reason text,
    occurred_at timestamptz NOT NULL
);

CREATE INDEX ride_events_ride ON ride_events (ride_id, id);
