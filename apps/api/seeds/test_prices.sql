-- Low weekly subscription prices for testing M-Pesa with real money.
-- Apply only to a test database, with `make seed-test-prices`. This file sits
-- outside migrations/ so that it can never reach production by deploying.
UPDATE vehicle_categories AS category
SET weekly_subscription_kes = test.kes, updated_at = now()
FROM (VALUES
    ('motorbike', 10),
    ('electric_motorbike', 15),
    ('basic', 20),
    ('send', 15),
    ('comfort', 25),
    ('xl', 30),
    ('women_only', 22),
    ('green', 20)
) AS test (slug, kes)
WHERE category.slug = test.slug;
