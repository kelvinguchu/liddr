package dispatch_test

import (
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestRideVisibility(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.inProgressRide(t)
	h.moveDriver(t, driver, near(50))

	seen, err := h.rides.Get(t.Context(), ride.ID, rider)
	if err != nil || seen.DriverLocation == nil {
		t.Fatalf("rider during trip = %+v, %v", seen, err)
	}
	if want := near(50); *seen.DriverLocation != (geo.Point{Lat: want.Lat, Lng: want.Lng}) {
		t.Errorf("location = %v", *seen.DriverLocation)
	}
	if _, err := h.rides.Get(t.Context(), ride.ID, uuid.New()); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("stranger = %v, want ErrRideNotFound", err)
	}

	h.moveDriver(t, driver, dropoff)
	if _, err := h.rides.CompleteTrip(t.Context(), ride.ID, driver, "cash_direct"); err != nil {
		t.Fatalf("CompleteTrip: %v", err)
	}
	after, err := h.rides.Get(t.Context(), ride.ID, rider)
	if err != nil || after.DriverLocation != nil {
		t.Errorf("rider after trip = %+v, %v; the driver's position must stop", after, err)
	}
}
