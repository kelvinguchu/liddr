package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestLeavingASharedTrip(t *testing.T) {
	t.Run("a second passenger can leave and the trip goes on", func(t *testing.T) {
		h := newHarness(t)
		ride, first, second, _ := h.group(t)
		if _, err := h.rides.Cancel(t.Context(), ride, second, "emergency"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		if got := h.status(t, ride); got != rides.StatusAccepted {
			t.Errorf("status = %s", got)
		}
		if got := h.memberStatus(t, h.memberOf(t, ride, first)); got != "assigned" {
			t.Errorf("remaining passenger = %s", got)
		}
	})
	t.Run("the trip passes to the remaining passenger when the first leaves", func(t *testing.T) {
		h := newHarness(t)
		ride, first, second, _ := h.group(t)
		if _, err := h.rides.Cancel(t.Context(), ride, first, "emergency"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		got, err := h.rides.Get(t.Context(), ride, second)
		if err != nil || got.Status != rides.StatusAccepted || got.Pickup != along(0.02) {
			t.Errorf("after the first passenger left = %+v, %v", got, err)
		}
		var owner uuid.UUID
		if err := h.pool.QueryRow(t.Context(), `SELECT rider_id FROM rides WHERE id = $1`, ride).Scan(&owner); err != nil || owner != second {
			t.Errorf("owner = %v, %v", owner, err)
		}
	})
	t.Run("the trip ends when the last passenger leaves", func(t *testing.T) {
		h := newHarness(t)
		ride, first, second, _ := h.group(t)
		for _, rider := range []uuid.UUID{first, second} {
			if _, err := h.rides.Cancel(t.Context(), ride, rider, "emergency"); err != nil && !errors.Is(err, rides.ErrRideNotFound) {
				t.Fatalf("Cancel: %v", err)
			}
		}
		if got := h.status(t, ride); got != rides.StatusCancelled {
			t.Errorf("status = %s", got)
		}
	})
	t.Run("nobody can leave once aboard", func(t *testing.T) {
		h := newHarness(t)
		ride, first, _, driver := h.group(t)
		h.moveDriver(t, driver, pickup)
		if _, err := h.rides.MarkArrived(t.Context(), ride, driver); err != nil {
			t.Fatalf("MarkArrived: %v", err)
		}
		h.board(t, ride, h.memberOf(t, ride, first), driver, pickup)
		if _, err := h.rides.Cancel(t.Context(), ride, first, "emergency"); !errors.Is(err, rides.ErrInvalidTransition) {
			t.Errorf("Cancel aboard = %v", err)
		}
	})
	t.Run("a driver cancelling ends it for everyone", func(t *testing.T) {
		h := newHarness(t)
		ride, first, second, driver := h.group(t)
		m1, m2 := h.memberOf(t, ride, first), h.memberOf(t, ride, second)
		if _, err := h.rides.Cancel(t.Context(), ride, driver, "vehicle_issue"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		if h.memberStatus(t, m1) != "cancelled" || h.memberStatus(t, m2) != "cancelled" {
			t.Errorf("members = %s, %s", h.memberStatus(t, m1), h.memberStatus(t, m2))
		}
	})
}

func TestMemberNoShow(t *testing.T) {
	h := newHarness(t)
	ride, first, second, driver := h.group(t)
	m2 := h.memberOf(t, ride, second)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	h.board(t, ride, h.memberOf(t, ride, first), driver, pickup)
	if _, err := h.rides.StartTrip(t.Context(), ride, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	h.moveDriver(t, driver, along(0.02))
	if err := h.rides.ArriveMember(t.Context(), ride, m2, driver); err != nil {
		t.Fatalf("ArriveMember: %v", err)
	}
	if err := h.rides.MarkMemberNoShow(t.Context(), ride, m2, driver); !errors.Is(err, rides.ErrNoShowTooEarly) {
		t.Errorf("no-show too early = %v", err)
	}
	h.clock.Advance(5 * time.Minute)
	h.moveDriver(t, driver, along(0.02))
	if err := h.rides.MarkMemberNoShow(t.Context(), ride, m2, driver); err != nil {
		t.Fatalf("MarkMemberNoShow: %v", err)
	}
	if got := h.strikes(t, second); got != 1 {
		t.Errorf("strikes = %d", got)
	}
	if got := h.status(t, ride); got != rides.StatusInProgress {
		t.Errorf("status = %s", got)
	}
}

func TestDestinationCannotChangeOnASharedTrip(t *testing.T) {
	h := newHarness(t)
	ride, first, _, driver := h.group(t)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	h.board(t, ride, h.memberOf(t, ride, first), driver, pickup)
	if _, err := h.rides.StartTrip(t.Context(), ride, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	_, err := h.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: ride, RiderID: first, Dropoff: elsewhere, Reason: "other"})
	if !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("RequestDestination = %v", err)
	}
}
