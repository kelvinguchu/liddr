package testdb

import (
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Seeder inserts fixtures for domains that need a finished ride to exist. It
// writes rows directly because those domains are not under test here.
type Seeder struct {
	Pool *pgxpool.Pool
	next int
}

// User creates an account with the given role and returns its id.
func (s *Seeder) User(t *testing.T, role string) uuid.UUID {
	t.Helper()
	s.next++
	id := uuid.New()
	s.exec(t, `INSERT INTO users (id, phone) VALUES ($1, $2)`, id, fmt.Sprintf("2547%08d", s.next))
	s.exec(t, `INSERT INTO user_roles (user_id, role) VALUES ($1, $2)`, id, role)
	if role == "driver" {
		s.exec(t, `INSERT INTO drivers (user_id, vehicle_category_id, verification_status) VALUES ($1, (SELECT min(id) FROM vehicle_categories), 'approved')`, id)
	}
	return id
}

// Ride is a ride to create.
type Ride struct {
	Rider   uuid.UUID
	Driver  *uuid.UUID
	Status  string
	FareKES int32
	Ended   time.Time
}

// Ride creates a ride and returns its id.
func (s *Seeder) Ride(t *testing.T, r Ride) uuid.UUID {
	t.Helper()
	quote, id := uuid.New(), uuid.New()
	s.exec(t, `INSERT INTO ride_quotes (id, rider_id, vehicle_category_id, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
		distance_m, duration_s, polyline, surge_bps, subtotal_cents, base_fare_kes, discount_kes, final_fare_kes, expires_at, created_at)
		VALUES ($1, $2, (SELECT min(id) FROM vehicle_categories), -1.29, 36.82, -1.30, 36.80, 1000, 100, 'x', 10000, 0, 0, 0, $3, $4, $4)`,
		quote, r.Rider, r.FareKES, r.Ended)
	var completed, cancelled *time.Time
	switch r.Status {
	case "completed":
		completed = &r.Ended
	case "cancelled":
		cancelled = &r.Ended
	}
	s.exec(t, `INSERT INTO rides (id, rider_id, driver_id, quote_id, vehicle_category_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
		fare_kes, search_expires_at, requested_at, completed_at, cancelled_at)
		VALUES ($1, $2, $3, $4, (SELECT min(id) FROM vehicle_categories), $5, -1.29, 36.82, -1.30, 36.80, $6, $7, $7, $8, $9)`,
		id, r.Rider, r.Driver, quote, r.Status, r.FareKES, r.Ended, completed, cancelled)
	return id
}

// OpenRatings invites both parties to rate a completed ride.
func (s *Seeder) OpenRatings(t *testing.T, ride, rider, driver uuid.UUID, due time.Time) {
	t.Helper()
	s.exec(t, `INSERT INTO rating_actions (ride_id, rated_by, rated_user, rater_role, status, due_at) VALUES
		($1, $2, $3, 'rider', 'pending', $4), ($1, $3, $2, 'driver', 'pending', $4)`, ride, rider, driver, due)
}

func (s *Seeder) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := s.Pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("seed: %v", err)
	}
}
