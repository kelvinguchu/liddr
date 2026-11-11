-- name: ListActiveVehicleCategories :many
SELECT slug, label, capacity, weekly_subscription_kes
FROM vehicle_categories
WHERE is_active
ORDER BY display_order;
