package dispatch_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

var (
	pickup  = geo.Point{Lat: -1.2921, Lng: 36.8219}
	dropoff = geo.Point{Lat: -1.3000, Lng: 36.8000}
)

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

type harness struct {
	rides      *rides.Service
	dispatch   *dispatch.Service
	pool       *pgxpool.Pool
	clock      *clock
	routesDown *atomic.Bool
	nextPhone  atomic.Int64
	routeCalls *atomic.Int64
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pool := testdb.Pool(t)
	down := &atomic.Bool{}
	calls := &atomic.Int64{}
	google := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		if down.Load() {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = fmt.Fprint(w, `{"routes":[{"distanceMeters":5000,"duration":"900s","polyline":{"encodedPolyline":"xyz"}}]}`)
	}))
	t.Cleanup(google.Close)

	// 09:00 UTC is midday in Nairobi on a Monday, when there is no time surge.
	c := &clock{now: time.Date(2026, 11, 9, 9, 0, 0, 0, time.UTC)}
	return &harness{
		rides:      rides.NewService(rides.Config{Pool: pool, Routes: maps.NewClient(google.URL, "key"), Moderation: moderation.NewService(moderation.Config{Pool: pool, Now: c.Now}), Now: c.Now}),
		dispatch:   dispatch.NewService(dispatch.Config{Pool: pool, Now: c.Now}),
		pool:       pool,
		clock:      c,
		routesDown: down,
		routeCalls: calls,
	}
}

func (h *harness) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := h.pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func (h *harness) newUser(t *testing.T, role string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	phone := fmt.Sprintf("25470%07d", h.nextPhone.Add(1))
	if err := h.pool.QueryRow(t.Context(), `INSERT INTO users (phone) VALUES ($1) RETURNING id`, phone).Scan(&id); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	h.exec(t, `INSERT INTO user_roles (user_id, role) VALUES ($1, $2)`, id, role)
	return id
}

type driverSpec struct {
	category     string
	verification string
	subscription string
	offline      bool
	account      string
	at           geo.Point
	locationAge  time.Duration
}

func near(metresNorth float64) geo.Point {
	return geo.Point{Lat: pickup.Lat + metresNorth/111_000, Lng: pickup.Lng}
}

func (h *harness) newDriver(t *testing.T, spec driverSpec) uuid.UUID {
	t.Helper()
	if spec.category == "" {
		spec.category = "motorbike"
	}
	if spec.verification == "" {
		spec.verification = "approved"
	}
	if spec.subscription == "" {
		spec.subscription = "active"
	}
	if spec.at == (geo.Point{}) {
		spec.at = near(200)
	}
	id := h.newUser(t, "driver")
	h.exec(t, `INSERT INTO drivers (user_id, vehicle_category_id, verification_status, subscription_status, is_online)
		SELECT $1, id, $3, $4, $5 FROM vehicle_categories WHERE slug = $2`,
		id, spec.category, spec.verification, spec.subscription, !spec.offline)
	h.exec(t, `INSERT INTO driver_locations (driver_id, lat, lng, captured_at) VALUES ($1, $2, $3, $4)`,
		id, spec.at.Lat, spec.at.Lng, h.clock.Now().Add(-spec.locationAge))
	if spec.account != "" {
		h.exec(t, `UPDATE users SET account_status = $1 WHERE id = $2`, spec.account, id)
	}
	return id
}

// moveDriver stores a position directly, bypassing the ping limit.
func (h *harness) moveDriver(t *testing.T, driver uuid.UUID, to geo.Point) {
	t.Helper()
	h.exec(t, `UPDATE driver_locations SET lat = $1, lng = $2, captured_at = $3 WHERE driver_id = $4`, to.Lat, to.Lng, h.clock.Now(), driver)
}

func (h *harness) quote(t *testing.T, rider uuid.UUID) rides.Quote {
	t.Helper()
	quote, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: "motorbike", Pickup: pickup, Dropoff: dropoff})
	if err != nil {
		t.Fatalf("CreateQuote: %v", err)
	}
	return quote
}

func (h *harness) book(t *testing.T, rider uuid.UUID) rides.Ride {
	t.Helper()
	ride, err := h.rides.Book(t.Context(), rider, h.quote(t, rider).ID)
	if err != nil {
		t.Fatalf("Book: %v", err)
	}
	return ride
}

func (h *harness) runDue(t *testing.T) {
	t.Helper()
	if err := h.dispatch.RunDue(t.Context()); err != nil {
		t.Fatalf("RunDue: %v", err)
	}
}

func (h *harness) offers(t *testing.T, driver uuid.UUID) []dispatch.Offer {
	t.Helper()
	offers, err := h.dispatch.ListOffers(t.Context(), driver)
	if err != nil {
		t.Fatalf("ListOffers: %v", err)
	}
	return offers
}

func (h *harness) status(t *testing.T, rideID uuid.UUID) string {
	t.Helper()
	var status string
	if err := h.pool.QueryRow(t.Context(), `SELECT status FROM rides WHERE id = $1`, rideID).Scan(&status); err != nil {
		t.Fatalf("read status: %v", err)
	}
	return status
}

// acceptedRide returns a ride already assigned to a new driver near pickup.
func (h *harness) acceptedRide(t *testing.T) (ride rides.Ride, rider, driver uuid.UUID) {
	t.Helper()
	rider = h.newUser(t, "rider")
	driver = h.newDriver(t, driverSpec{})
	ride = h.book(t, rider)
	h.runDue(t)
	offers := h.offers(t, driver)
	if len(offers) != 1 {
		t.Fatalf("offers = %d, want 1", len(offers))
	}
	if _, err := h.dispatch.Accept(t.Context(), driver, offers[0].ID); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	return ride, rider, driver
}

func (h *harness) inProgressRide(t *testing.T) (ride rides.Ride, rider, driver uuid.UUID) {
	t.Helper()
	ride, rider, driver = h.acceptedRide(t)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	if _, err := h.rides.StartTrip(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	return ride, rider, driver
}
