package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func (h *harness) strikes(t *testing.T, subject uuid.UUID) int64 {
	t.Helper()
	var count int64
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM ride_integrity_events WHERE subject_id = $1 AND chargeable`, subject).Scan(&count); err != nil {
		t.Fatalf("count strikes: %v", err)
	}
	return count
}

func TestWhetherACancellationCountsAgainstTheRider(t *testing.T) {
	cases := []struct {
		name       string
		advance    time.Duration
		at         float64
		reason     string
		chargeable bool
	}{
		{"within the free window", 60 * time.Second, 150, "rider_changed_mind", false},
		{"after the free window", 150 * time.Second, 100, "rider_changed_mind", true},
		{"emergency", 150 * time.Second, 100, "emergency", false},
		{"driver really is not moving", 181 * time.Second, 200, "driver_not_moving", false},
		{"claims not moving but driver is coming", 181 * time.Second, 20, "driver_not_moving", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			ride, rider, driver := h.acceptedRide(t)
			h.clock.Advance(tc.advance)
			h.moveDriver(t, driver, near(tc.at))
			if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, tc.reason); err != nil {
				t.Fatalf("Cancel: %v", err)
			}
			if got := h.strikes(t, rider) == 1; got != tc.chargeable {
				t.Errorf("chargeable = %v, want %v", got, tc.chargeable)
			}
		})
	}
}

func TestDriverCancelsCountUnlessJustified(t *testing.T) {
	for reason, want := range map[string]int64{"cannot_contact_rider": 1, "vehicle_issue": 0} {
		t.Run(reason, func(t *testing.T) {
			h := newHarness(t)
			ride, _, driver := h.acceptedRide(t)
			if _, err := h.rides.Cancel(t.Context(), ride.ID, driver, reason); err != nil {
				t.Fatalf("Cancel: %v", err)
			}
			if got := h.strikes(t, driver); got != want {
				t.Errorf("strikes = %d, want %d", got, want)
			}
		})
	}
}

func (h *harness) seedStrikes(t *testing.T, subject uuid.UUID, role string, n int) {
	t.Helper()
	for range n {
		ride, _, seeded := h.acceptedRide(t)
		h.exec(t, `UPDATE rides SET status = 'cancelled', cancelled_at = $2 WHERE id = $1`, ride.ID, h.clock.Now())
		h.exec(t, `UPDATE drivers SET is_online = false WHERE user_id = $1`, seeded)
		h.exec(t, `INSERT INTO ride_integrity_events (ride_id, subject_id, subject_role, violation_type, reason_code, chargeable, occurred_at)
			VALUES ($1, $2, $3, 'cancellation', 'seed', true, $4)`, ride.ID, subject, role, h.clock.Now())
	}
}

func TestFifthStrikePausesARidersBookingsOnce(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	h.seedStrikes(t, rider, "rider", 4)
	ride, _, driver := h.acceptedRide(t)
	h.exec(t, `UPDATE rides SET rider_id = $1 WHERE id = $2`, rider, ride.ID)
	h.clock.Advance(150 * time.Second)
	h.moveDriver(t, driver, near(100))
	if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	standing, err := h.rides.Standing(t.Context(), rider)
	if err != nil || standing.RiderStrikes != 5 || standing.BookingRestricted == nil {
		t.Fatalf("Standing = %+v, %v", standing, err)
	}
	if _, err := h.rides.Book(t.Context(), rider, h.quote(t, rider).ID); !errors.Is(err, rides.ErrBookingRestricted) {
		t.Errorf("Book while restricted = %v", err)
	}
	h.clock.Advance(7*24*time.Hour + time.Minute)
	if _, err := h.rides.Book(t.Context(), rider, h.quote(t, rider).ID); err != nil {
		t.Errorf("Book after the restriction = %v", err)
	}
}

func TestDriverIsSuspendedOnceNotOnEveryLaterCancel(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.acceptedRide(t)
	h.seedStrikes(t, driver, "driver", 4)
	if _, err := h.rides.Cancel(t.Context(), ride.ID, driver, "cannot_contact_rider"); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	var suspensions int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM user_enforcements WHERE user_id = $1 AND action = 'temporary_suspension'`, driver).Scan(&suspensions); err != nil || suspensions != 1 {
		t.Fatalf("suspensions = %d, %v", suspensions, err)
	}
	var status string
	if err := h.pool.QueryRow(t.Context(), `SELECT account_status FROM users WHERE id = $1`, driver).Scan(&status); err != nil || status != "suspended" {
		t.Errorf("account = %s, %v", status, err)
	}
	h.seedStrikes(t, driver, "driver", 1)
	var more int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM user_enforcements WHERE user_id = $1`, driver).Scan(&more); err != nil || more != 1 {
		t.Errorf("enforcements after a sixth strike = %d, %v", more, err)
	}
}

func TestNoShowCountsAgainstTheRiderOnce(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.acceptedRide(t)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	h.clock.Advance(5 * time.Minute)
	h.moveDriver(t, driver, pickup)
	for range 2 {
		if _, err := h.rides.MarkNoShow(t.Context(), ride.ID, driver); err != nil {
			t.Fatalf("MarkNoShow: %v", err)
		}
	}
	if got := h.strikes(t, rider); got != 1 {
		t.Errorf("strikes = %d, want 1", got)
	}
}
