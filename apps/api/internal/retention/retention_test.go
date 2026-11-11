package retention_test

import (
	"log/slog"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/retention"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestSweepRemovesOnlyWhatHasExpired(t *testing.T) {
	pool := testdb.Pool(t)
	seed := &testdb.Seeder{Pool: pool}
	now := time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(t.Context(), sql, args...); err != nil {
			t.Fatalf("exec: %v", err)
		}
	}
	count := func(table string) (n int) {
		t.Helper()
		if err := pool.QueryRow(t.Context(), `SELECT count(*) FROM `+table).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", table, err)
		}
		return n
	}

	rider := seed.User(t, "rider")
	driver := seed.User(t, "driver")
	old := now.AddDate(0, 0, -100)
	oldRide := seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: "completed", FareKES: 100, Ended: old})
	recentRide := seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: "completed", FareKES: 100, Ended: now})
	exec(`UPDATE ride_quotes SET created_at = $1`, old)

	for _, ride := range []uuid.UUID{oldRide, recentRide} {
		exec(`INSERT INTO ride_messages (id, ride_id, sender_id, recipient_id, sender_role, message_type, body, created_at)
			VALUES ($1, $2, $3, $4, 'rider', 'text', 'hi', $5)`, uuid.New(), ride, rider, driver, now)
	}
	exec(`INSERT INTO ride_quotes (id, rider_id, vehicle_category_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
		distance_m, duration_s, polyline, surge_bps, subtotal_cents, base_fare_kes, discount_kes, final_fare_kes, expires_at, created_at)
		VALUES (gen_random_uuid(), $1, (SELECT min(id) FROM vehicle_categories), 0, 0, 0, 0, 1, 1, 'x', 10000, 0, 0, 0, 0, $2, $2)`, rider, old)
	exec(`INSERT INTO notifications (user_id, event_type, created_at) VALUES ($1, 'x', $2), ($1, 'y', $3)`, rider, old, now)
	exec(`INSERT INTO audit_events (action, request_id, ip, created_at) VALUES ('a', 'r', '127.0.0.1', $1), ('b', 'r', '127.0.0.1', $2)`, now.AddDate(-2, 0, 0), now.AddDate(0, -6, 0))

	sweeper := retention.NewSweeper(store.New(pool), func() time.Time { return now }, slog.New(slog.DiscardHandler))
	if err := sweeper.Sweep(t.Context()); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	for table, want := range map[string]int{"ride_messages": 1, "notifications": 1, "audit_events": 1, "ride_quotes": 2, "rides": 2} {
		if got := count(table); got != want {
			t.Errorf("%s = %d, want %d", table, got, want)
		}
	}
}
