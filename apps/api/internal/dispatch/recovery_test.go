package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestReassignNeedsARealSignOfTrouble(t *testing.T) {
	h := newHarness(t)
	ride, rider, _ := h.acceptedRide(t)
	if _, err := h.rides.Reassign(t.Context(), ride.ID, rider); !errors.Is(err, rides.ErrReassignNotAllowed) {
		t.Errorf("Reassign with a healthy driver = %v", err)
	}
	stranger := h.newUser(t, "rider")
	if _, err := h.rides.Reassign(t.Context(), ride.ID, stranger); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("Reassign by a stranger = %v", err)
	}
}

func TestReassignReleasesTheDriverAndNeverReoffersThem(t *testing.T) {
	h := newHarness(t)
	ride, rider, first := h.acceptedRide(t)
	h.clock.Advance(121 * time.Second)
	moved, err := h.rides.Reassign(t.Context(), ride.ID, rider)
	if err != nil {
		t.Fatalf("Reassign: %v", err)
	}
	if moved.Status != rides.StatusSearching || moved.DriverID != nil {
		t.Fatalf("after reassign = %+v", moved)
	}
	h.moveDriver(t, first, near(100))
	second := h.newDriver(t, driverSpec{})
	h.runDue(t)
	if got := h.offers(t, first); len(got) != 0 {
		t.Errorf("the released driver was offered the ride again: %v", got)
	}
	if got := h.offers(t, second); len(got) != 1 {
		t.Errorf("new driver offers = %v", got)
	}
}

func TestHealthSignals(t *testing.T) {
	cases := []struct {
		name    string
		advance time.Duration
		at      geo.Point
		fresh   bool
		check   func(rides.Health) bool
	}{
		{"healthy just after accepting", 30 * time.Second, near(150), true, func(h rides.Health) bool { return !h.RecommendReassign() }},
		{"stationary driver is flagged", 181 * time.Second, near(200), true, func(h rides.Health) bool { return h.NoProgress }},
		{"approaching driver is not", 181 * time.Second, near(50), true, func(h rides.Health) bool { return !h.NoProgress && !h.MovingAway }},
		{"driver going the wrong way", 121 * time.Second, near(800), true, func(h rides.Health) bool { return h.MovingAway }},
		{"no recent position", 121 * time.Second, near(200), false, func(h rides.Health) bool { return h.LocationStale }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			ride, rider, driver := h.acceptedRide(t)
			h.clock.Advance(tc.advance)
			if tc.fresh {
				h.moveDriver(t, driver, tc.at)
			}
			got, err := h.rides.PickupHealth(t.Context(), ride.ID, rider)
			if err != nil {
				t.Fatalf("PickupHealth: %v", err)
			}
			if !tc.check(got) {
				t.Errorf("health = %+v", got)
			}
		})
	}
}

func TestWatchdog(t *testing.T) {
	t.Run("leaves a healthy pickup alone", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.acceptedRide(t)
		h.clock.Advance(130 * time.Second)
		h.moveDriver(t, driver, near(100))
		if err := h.rides.CheckPickups(t.Context()); err != nil {
			t.Fatalf("CheckPickups: %v", err)
		}
		if got := h.status(t, ride.ID); got != rides.StatusAccepted {
			t.Errorf("status = %s", got)
		}
	})
	t.Run("leaves a long pickup alone while the driver is closing in", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.acceptedRide(t)
		h.exec(t, `UPDATE rides SET pickup_distance_m_at_accept = 6000, pickup_eta_s_at_accept = 1100 WHERE id = $1`, ride.ID)
		h.clock.Advance(450 * time.Second)
		h.moveDriver(t, driver, near(3000))
		if err := h.rides.CheckPickups(t.Context()); err != nil {
			t.Fatalf("CheckPickups: %v", err)
		}
		if got := h.status(t, ride.ID); got != rides.StatusAccepted {
			t.Errorf("a driver on the way was replaced: %s", got)
		}
	})
	t.Run("finds another driver and records no rider as the actor", func(t *testing.T) {
		h := newHarness(t)
		ride, _, _ := h.acceptedRide(t)
		h.clock.Advance(181 * time.Second)
		if err := h.rides.CheckPickups(t.Context()); err != nil {
			t.Fatalf("CheckPickups: %v", err)
		}
		if got := h.status(t, ride.ID); got != rides.StatusSearching {
			t.Fatalf("status = %s", got)
		}
		var actor *uuid.UUID
		err := h.pool.QueryRow(t.Context(), `SELECT actor_user_id FROM ride_events WHERE ride_id = $1 AND reason = 'pickup_watchdog'`, ride.ID).Scan(&actor)
		if err != nil || actor != nil {
			t.Errorf("actor = %v, %v, want none", actor, err)
		}
	})
	t.Run("gives up after a second driver also fails", func(t *testing.T) {
		h := newHarness(t)
		ride, _, _ := h.acceptedRide(t)
		h.exec(t, `UPDATE rides SET reassign_count = 1 WHERE id = $1`, ride.ID)
		h.clock.Advance(901 * time.Second)
		if err := h.rides.CheckPickups(t.Context()); err != nil {
			t.Fatalf("CheckPickups: %v", err)
		}
		var status, by string
		if err := h.pool.QueryRow(t.Context(), `SELECT status, cancelled_by FROM rides WHERE id = $1`, ride.ID).Scan(&status, &by); err != nil {
			t.Fatalf("read ride: %v", err)
		}
		if status != rides.StatusCancelled || by != "system" {
			t.Errorf("ride = %s by %s", status, by)
		}
	})
}

func (h *harness) tripUnderWay(t *testing.T) (rides.Ride, uuid.UUID, uuid.UUID) {
	t.Helper()
	ride, rider, driver := h.acceptedRide(t)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	if _, err := h.rides.StartTrip(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	h.moveDriver(t, driver, near(500))
	return ride, rider, driver
}

func TestHistoryAndTimelineBelongToTheParties(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.acceptedRide(t)
	asRider, err := h.rides.History(t.Context(), rider, false, nil, 10, 0)
	if err != nil || len(asRider) != 1 || asRider[0].ID != ride.ID {
		t.Errorf("rider history = %+v, %v", asRider, err)
	}
	asDriver, err := h.rides.History(t.Context(), driver, true, new("send"), 10, 0)
	if err != nil || len(asDriver) != 0 {
		t.Errorf("driver send history = %+v, %v", asDriver, err)
	}
	stranger := h.newUser(t, "rider")
	if _, err := h.rides.Timeline(t.Context(), ride.ID, stranger); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("Timeline by a stranger = %v", err)
	}
	if steps, err := h.rides.Timeline(t.Context(), ride.ID, rider); err != nil || len(steps) != 2 {
		t.Errorf("Timeline = %+v, %v", steps, err)
	}
}
