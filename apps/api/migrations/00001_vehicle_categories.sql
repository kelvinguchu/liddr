-- +goose Up
CREATE TABLE vehicle_categories (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    label text NOT NULL,
    capacity integer NOT NULL CHECK (capacity >= 0),
    weekly_subscription_kes integer NOT NULL CHECK (weekly_subscription_kes >= 0),
    is_active boolean NOT NULL,
    display_order integer NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Tiers and launch phases come from docs/aboutapp.md sections 1.1 and 1.2.
INSERT INTO vehicle_categories
    (slug, label, capacity, weekly_subscription_kes, is_active, display_order)
VALUES
    ('motorbike', 'Motorbike', 1, 1000, true, 10),
    ('electric_motorbike', 'Electric Motorbike', 1, 1000, true, 20),
    ('basic', 'Basic', 3, 2000, true, 30),
    ('send', 'Send', 0, 1500, true, 40),
    ('comfort', 'Comfort', 4, 2500, false, 50),
    ('xl', 'XL', 6, 3000, false, 60),
    ('women_only', 'Women Only', 3, 2000, false, 70),
    ('green', 'Green', 3, 2000, false, 80);
