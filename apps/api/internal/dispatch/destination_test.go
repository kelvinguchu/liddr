package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

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

func TestAnUnansweredRequestDoesNotBlockTheRider(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.tripUnderWay(t)
	h.askDestination(t, ride.ID, rider)
	h.clock.Advance(181 * time.Second)
	h.moveDriver(t, driver, near(600))
	h.askDestination(t, ride.ID, rider)
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
