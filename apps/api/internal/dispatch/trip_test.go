package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestFullTripChargesQuotedFareAndAuditsEveryStep(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.acceptedRide(t)
	h.moveDriver(t, driver, pickup)

	if _, err := h.rides.MarkArriving(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArriving: %v", err)
	}
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	if _, err := h.rides.StartTrip(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	h.moveDriver(t, driver, dropoff)
	done, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct")
	if err != nil {
		t.Fatalf("CompleteTrip: %v", err)
	}
	if done.FareKES != ride.FareKES || done.Status != rides.StatusCompleted {
		t.Errorf("completed ride = %+v, want fare %d", done, ride.FareKES)
	}

	rows, err := h.pool.Query(t.Context(), `SELECT COALESCE(from_status, ''), to_status FROM ride_events WHERE ride_id = $1 ORDER BY id`, ride.ID)
	if err != nil {
		t.Fatalf("query events: %v", err)
	}
	defer rows.Close()
	var got [][2]string
	for rows.Next() {
		var from, to string
		if err := rows.Scan(&from, &to); err != nil {
			t.Fatalf("scan event: %v", err)
		}
		got = append(got, [2]string{from, to})
	}
	want := [][2]string{
		{"", "searching"}, {"searching", "accepted"}, {"accepted", "driver_arriving"},
		{"driver_arriving", "arrived"}, {"arrived", "in_progress"}, {"in_progress", "completed"},
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("events mismatch (-got +want):\n%s", diff)
	}
}

func TestIllegalStepsAreRefused(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.acceptedRide(t)
	h.moveDriver(t, driver, dropoff)

	if _, err := h.rides.StartTrip(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("start before arrival = %v", err)
	}
	if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct"); !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("complete before start = %v", err)
	}
	if _, err := h.rides.MarkNoShow(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("no-show before arrival = %v", err)
	}
}

func TestRetriedDriverActionsReturnTheRide(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.inProgressRide(t)

	// The driver has since left pickup, so a retried arrival must not re-run the fence.
	h.moveDriver(t, driver, dropoff)
	if _, err := h.rides.StartTrip(t.Context(), ride.ID, driver); err != nil {
		t.Errorf("repeat start = %v", err)
	}
	if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "mpesa_direct"); err != nil {
		t.Fatalf("CompleteTrip: %v", err)
	}
	again, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct")
	if err != nil {
		t.Fatalf("repeat complete = %v", err)
	}
	if again.PaymentMode == nil || *again.PaymentMode != "mpesa_direct" {
		t.Errorf("a retry changed the payment mode: %v", again.PaymentMode)
	}
}

func TestGeofences(t *testing.T) {
	t.Run("too far from pickup", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.acceptedRide(t)
		h.moveDriver(t, driver, near(130))
		if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrTooFarFromPickup) {
			t.Errorf("MarkArrived = %v, want ErrTooFarFromPickup", err)
		}
	})
	t.Run("stale position", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.acceptedRide(t)
		h.moveDriver(t, driver, pickup)
		h.clock.Advance(2*time.Minute + time.Second)
		if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrLocationUnknown) {
			t.Errorf("MarkArrived = %v, want ErrLocationUnknown", err)
		}
	})
	t.Run("too far from dropoff", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.inProgressRide(t)
		if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct"); !errors.Is(err, rides.ErrTooFarFromDropoff) {
			t.Errorf("CompleteTrip = %v, want ErrTooFarFromDropoff", err)
		}
	})
	t.Run("invalid payment mode", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.inProgressRide(t)
		if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "free"); !errors.Is(err, rides.ErrInvalidPaymentMode) {
			t.Errorf("CompleteTrip = %v, want ErrInvalidPaymentMode", err)
		}
	})
}

func TestOnlyTheAssignedDriverCanAct(t *testing.T) {
	h := newHarness(t)
	ride, _, _ := h.acceptedRide(t)
	stranger := h.newDriver(t, driverSpec{offline: true, at: pickup})
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, stranger); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("MarkArrived = %v, want ErrRideNotFound", err)
	}
	if _, err := h.rides.Cancel(t.Context(), ride.ID, stranger, "emergency"); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("Cancel = %v, want ErrRideNotFound", err)
	}
}

func TestCancellationRules(t *testing.T) {
	t.Run("rider while searching withdraws offers", func(t *testing.T) {
		h := newHarness(t)
		driver := h.newDriver(t, driverSpec{})
		rider := h.newUser(t, "rider")
		ride := h.book(t, rider)
		h.runDue(t)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		if got := len(h.offers(t, driver)); got != 0 {
			t.Errorf("offers = %d, want 0", got)
		}
	})
	t.Run("reason must belong to the caller's side", func(t *testing.T) {
		h := newHarness(t)
		ride, rider, driver := h.acceptedRide(t)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "vehicle_issue"); !errors.Is(err, rides.ErrInvalidReason) {
			t.Errorf("rider = %v, want ErrInvalidReason", err)
		}
		if _, err := h.rides.Cancel(t.Context(), ride.ID, driver, "rider_changed_mind"); !errors.Is(err, rides.ErrInvalidReason) {
			t.Errorf("driver = %v, want ErrInvalidReason", err)
		}
	})
	t.Run("rider cannot cancel a started trip", func(t *testing.T) {
		h := newHarness(t)
		ride, rider, _ := h.inProgressRide(t)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "emergency"); !errors.Is(err, rides.ErrInvalidTransition) {
			t.Errorf("Cancel = %v, want ErrInvalidTransition", err)
		}
	})
	t.Run("driver needs a serious reason once started", func(t *testing.T) {
		h := newHarness(t)
		ride, _, driver := h.inProgressRide(t)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, driver, "cannot_contact_rider"); !errors.Is(err, rides.ErrInvalidReason) {
			t.Errorf("Cancel = %v, want ErrInvalidReason", err)
		}
		if _, err := h.rides.Cancel(t.Context(), ride.ID, driver, "vehicle_issue"); err != nil {
			t.Errorf("Cancel = %v, want nil", err)
		}
	})
	t.Run("cancel is idempotent", func(t *testing.T) {
		h := newHarness(t)
		ride, rider, _ := h.acceptedRide(t)
		for range 2 {
			if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
				t.Errorf("Cancel = %v", err)
			}
		}
	})
}

func TestNoShowRequiresFullWaitAtPickup(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.acceptedRide(t)
	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride.ID, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}

	h.clock.Advance(5*time.Minute - time.Second)
	if _, err := h.rides.MarkNoShow(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrNoShowTooEarly) {
		t.Errorf("early = %v, want ErrNoShowTooEarly", err)
	}
	h.clock.Advance(time.Second)
	h.moveDriver(t, driver, near(500))
	if _, err := h.rides.MarkNoShow(t.Context(), ride.ID, driver); !errors.Is(err, rides.ErrTooFarFromPickup) {
		t.Errorf("drove away = %v, want ErrTooFarFromPickup", err)
	}
	h.moveDriver(t, driver, pickup)
	got, err := h.rides.MarkNoShow(t.Context(), ride.ID, driver)
	if err != nil || got.Status != rides.StatusCancelled {
		t.Errorf("MarkNoShow = %+v, %v", got, err)
	}
}

func TestDriverIsFreeForNewOffersAfterTrip(t *testing.T) {
	h := newHarness(t)
	ride, _, driver := h.inProgressRide(t)
	h.moveDriver(t, driver, dropoff)
	if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct"); err != nil {
		t.Fatalf("CompleteTrip: %v", err)
	}
	h.moveDriver(t, driver, near(100))
	h.book(t, h.newUser(t, "rider"))
	h.runDue(t)
	if got := len(h.offers(t, driver)); got != 1 {
		t.Errorf("offers = %d, want 1", got)
	}
}
