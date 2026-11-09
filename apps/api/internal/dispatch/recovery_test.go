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

var elsewhere = geo.Point{Lat: dropoff.Lat + 0.01, Lng: dropoff.Lng}

func (h *harness) askDestination(t *testing.T, ride, rider uuid.UUID) rides.DestinationChange {
	t.Helper()
	change, err := h.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: ride, RiderID: rider, Dropoff: elsewhere, Reason: "other"})
	if err != nil {
		t.Fatalf("RequestDestination: %v", err)
	}
	return change
}

func TestDestinationChangePricesTheWholeTripDriven(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.tripUnderWay(t)
	change := h.askDestination(t, ride.ID, rider)
	if change.OldFareKES != ride.FareKES {
		t.Errorf("old fare = %d, want %d", change.OldFareKES, ride.FareKES)
	}
	// Both legs return 5 km and 15 minutes from the stub, so the new fare must
	// price 10 km, more than the 5 km originally quoted.
	if change.NewFareKES <= ride.FareKES {
		t.Errorf("new fare %d did not include the distance already driven (was %d)", change.NewFareKES, ride.FareKES)
	}
	if got, err := h.rides.Get(t.Context(), ride.ID, rider); err != nil || got.FareKES != ride.FareKES {
		t.Errorf("a request alone changed the fare: %+v, %v", got, err)
	}
	if err := h.rides.RespondDestination(t.Context(), ride.ID, change.ID, driver, true, nil); err != nil {
		t.Fatalf("accept: %v", err)
	}
	h.moveDriver(t, driver, elsewhere)
	done, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct")
	if err != nil {
		t.Fatalf("CompleteTrip at the new destination: %v", err)
	}
	if done.FareKES != change.NewFareKES {
		t.Errorf("final fare = %d, want the accepted %d", done.FareKES, change.NewFareKES)
	}
}

func TestDestinationChangeRules(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.tripUnderWay(t)
	bad := []struct {
		name string
		req  rides.DestinationRequest
		want error
	}{
		{"unknown reason", rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: elsewhere, Reason: "nope"}, rides.ErrInvalidReason},
		{"same place", rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: dropoff, Reason: "other"}, rides.ErrSameDestination},
		{"outside the country", rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: geo.Point{Lat: 51.5, Lng: 0}, Reason: "other"}, rides.ErrOutsideServiceArea},
		{"driver cannot ask", rides.DestinationRequest{RideID: ride.ID, RiderID: driver, Dropoff: elsewhere, Reason: "other"}, rides.ErrRideNotFound},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := h.rides.RequestDestination(t.Context(), tc.req); !errors.Is(err, tc.want) {
				t.Errorf("RequestDestination = %v, want %v", err, tc.want)
			}
		})
	}

	first := h.askDestination(t, ride.ID, rider)
	if _, err := h.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: elsewhere, Reason: "other"}); !errors.Is(err, rides.ErrDestinationPending) {
		t.Errorf("second open request = %v", err)
	}

	// An unanswered request lapses, and must not block the rider afterwards.
	h.clock.Advance(181 * time.Second)
	h.moveDriver(t, driver, near(600))
	if err := h.rides.RespondDestination(t.Context(), ride.ID, first.ID, driver, true, nil); !errors.Is(err, rides.ErrDestinationStale) {
		t.Errorf("accepting a lapsed request = %v", err)
	}
	second := h.askDestination(t, ride.ID, rider)
	if err := h.rides.RespondDestination(t.Context(), ride.ID, second.ID, driver, false, new("driver_declined")); err != nil {
		t.Fatalf("reject: %v", err)
	}
	if got, err := h.rides.Get(t.Context(), ride.ID, rider); err != nil || got.FareKES != ride.FareKES {
		t.Errorf("a rejected change moved the fare: %+v, %v", got, err)
	}
	h.clock.Advance(46 * time.Second)
	h.moveDriver(t, driver, near(700))
	if _, err := h.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: elsewhere, Reason: "other"}); !errors.Is(err, rides.ErrDestinationLimit) {
		t.Errorf("third request = %v", err)
	}
}

func TestDestinationCannotChangeBeforeTheTripOrOnADelivery(t *testing.T) {
	h := newHarness(t)
	ride, rider, _ := h.acceptedRide(t)
	if _, err := h.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: ride.ID, RiderID: rider, Dropoff: elsewhere, Reason: "other"}); !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("before the trip = %v", err)
	}

	send := newHarness(t)
	trip, sender, _ := send.tripUnderWay(t)
	send.exec(t, `INSERT INTO send_deliveries (ride_id, sender_name, sender_phone, recipient_name, recipient_phone, item_description,
		item_size, payer, payment_timing, liability_acknowledged, delivery_status, created_at, updated_at)
		VALUES ($1, 'a', 'b', 'c', 'd', 'e', 'small', 'sender', 'after', false, 'in_transit', now(), now())`, trip.ID)
	if _, err := send.rides.RequestDestination(t.Context(), rides.DestinationRequest{RideID: trip.ID, RiderID: sender, Dropoff: elsewhere, Reason: "other"}); !errors.Is(err, rides.ErrInvalidTransition) {
		t.Errorf("on a delivery = %v", err)
	}
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
