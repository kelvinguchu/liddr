package dispatch_test

import (
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestEachSideSeesWhoIsOnTheTrip(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.acceptedRide(t)
	h.exec(t, `UPDATE users SET display_name = 'Asha Njeri', rating_centi = 476, rating_count = 12 WHERE id = $1`, driver)
	h.exec(t, `UPDATE drivers SET plate_number = 'KMFB123A' WHERE user_id = $1`, driver)
	h.exec(t, `UPDATE users SET display_name = 'Juma Otieno', rating_centi = 350, rating_count = 9 WHERE id = $1`, rider)
	seed := &testdb.Seeder{Pool: h.pool}
	seed.Ride(t, testdb.Ride{Rider: rider, Driver: &driver, Status: "completed", FareKES: 100, Ended: h.clock.Now().Add(-time.Hour)})

	seen, err := h.rides.Get(t.Context(), ride.ID, rider)
	if err != nil {
		t.Fatalf("Get as rider: %v", err)
	}
	want := &rides.DriverCard{Name: new("Asha Njeri"), PlateNumber: new("KMFB123A"), VehicleCategory: "motorbike", CompletedRides: 1, Rating: new(4.8)}
	if diff := cmp.Diff(seen.Driver, want); diff != "" {
		t.Errorf("driver card (-got +want):\n%s", diff)
	}
	if seen.Rider != nil {
		t.Errorf("rider was shown their own card: %+v", seen.Rider)
	}

	seen, err = h.rides.Get(t.Context(), ride.ID, driver)
	if err != nil {
		t.Fatalf("Get as driver: %v", err)
	}
	if diff := cmp.Diff(seen.Rider, &rides.RiderCard{Name: new("Juma Otieno")}); diff != "" {
		t.Errorf("rider card, with too few ratings to show (-got +want):\n%s", diff)
	}
	if seen.Driver != nil {
		t.Errorf("driver was shown their own card: %+v", seen.Driver)
	}

	if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	seen, err = h.rides.Get(t.Context(), ride.ID, rider)
	if err != nil {
		t.Fatalf("Get after cancel: %v", err)
	}
	if seen.Driver != nil {
		t.Errorf("driver's details outlived the trip: %+v", seen.Driver)
	}
}

func TestOfferShowsARatedRidersScore(t *testing.T) {
	tests := []struct {
		name  string
		count int32
		want  *float64
	}{
		{name: "enough ratings", count: 10, want: new(3.5)},
		{name: "too few ratings", count: 9},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			rider := h.newUser(t, "rider")
			h.exec(t, `UPDATE users SET rating_centi = 350, rating_count = $2 WHERE id = $1`, rider, tt.count)
			driver := h.newDriver(t, driverSpec{})
			h.book(t, rider)
			h.runDue(t)
			offers := h.offers(t, driver)
			if len(offers) != 1 {
				t.Fatalf("offers = %d, want 1", len(offers))
			}
			if diff := cmp.Diff(offers[0].RiderRating, tt.want); diff != "" {
				t.Errorf("rider rating (-got +want):\n%s", diff)
			}
		})
	}
}

func TestSharedRideHidesOneRiderBehindTheGroup(t *testing.T) {
	h := newHarness(t)
	rideID, first, _, driver := h.group(t)
	h.exec(t, `UPDATE users SET rating_centi = 350, rating_count = 12 WHERE id = $1`, first)
	seen, err := h.rides.Get(t.Context(), rideID, driver)
	if err != nil {
		t.Fatalf("Get as driver: %v", err)
	}
	if seen.Rider != nil {
		t.Errorf("shared driver view named one rider: %+v", seen.Rider)
	}
	seen, err = h.rides.Get(t.Context(), rideID, first)
	if err != nil {
		t.Fatalf("Get as rider: %v", err)
	}
	if seen.Driver == nil {
		t.Error("shared rider cannot see who is coming")
	}
}

func TestEarningsUseNairobiDaysAndMondayWeeks(t *testing.T) {
	h := newHarness(t) // Monday 12:00 in Nairobi.
	rider := h.newUser(t, "rider")
	driver := h.newDriver(t, driverSpec{})
	other := h.newDriver(t, driverSpec{})
	seed := &testdb.Seeder{Pool: h.pool}
	at := func(y time.Month, d, hour int) time.Time { return time.Date(2026, y, d, hour, 0, 0, 0, time.UTC) }
	for _, r := range []testdb.Ride{
		{Rider: rider, Driver: &driver, Status: "completed", FareKES: 300, Ended: at(time.November, 9, 8)},
		// 01:00 Monday in Nairobi, though still Sunday in UTC.
		{Rider: rider, Driver: &driver, Status: "completed", FareKES: 200, Ended: at(time.November, 8, 22)},
		// 23:00 Sunday in Nairobi: last week.
		{Rider: rider, Driver: &driver, Status: "completed", FareKES: 150, Ended: at(time.November, 8, 20)},
		// 01:00 six days back in Nairobi: the oldest day still inside the window.
		{Rider: rider, Driver: &driver, Status: "completed", FareKES: 70, Ended: at(time.November, 2, 22)},
		// Eight days back: outside the window.
		{Rider: rider, Driver: &driver, Status: "completed", FareKES: 999, Ended: at(time.November, 1, 8)},
		{Rider: rider, Driver: &driver, Status: "cancelled", FareKES: 999, Ended: at(time.November, 9, 8)},
		{Rider: rider, Driver: &other, Status: "completed", FareKES: 999, Ended: at(time.November, 9, 8)},
	} {
		seed.Ride(t, r)
	}
	got, err := h.rides.Earnings(t.Context(), driver)
	if err != nil {
		t.Fatalf("Earnings: %v", err)
	}
	want := rides.Earnings{
		Today: rides.EarningsPeriod{Trips: 2, TotalKES: 500},
		Week:  rides.EarningsPeriod{Trips: 2, TotalKES: 500},
		Days: []rides.EarningsDay{
			{Date: at(time.November, 9, 0), Trips: 2, TotalKES: 500},
			{Date: at(time.November, 8, 0), Trips: 1, TotalKES: 150},
			{Date: at(time.November, 3, 0), Trips: 1, TotalKES: 70},
		},
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("earnings (-got +want):\n%s", diff)
	}
}

func TestSharedEarningsCountOnlyPassengersWhoTravelled(t *testing.T) {
	h := newHarness(t)
	rideID, _, second, driver := h.group(t)
	h.exec(t, `UPDATE shared_members SET status = 'cancelled' WHERE ride_id = $1 AND rider_id = $2`, rideID, second)
	h.exec(t, `UPDATE shared_members SET status = 'dropped_off', fare_kes = 240 WHERE ride_id = $1 AND rider_id <> $2`, rideID, second)
	h.exec(t, `UPDATE rides SET status = 'completed', completed_at = $2, fare_kes = 1 WHERE id = $1`, rideID, h.clock.Now())
	got, err := h.rides.Earnings(t.Context(), driver)
	if err != nil {
		t.Fatalf("Earnings: %v", err)
	}
	if got.Today.TotalKES != 240 || got.Today.Trips != 1 {
		t.Errorf("today = %+v, want one trip of 240", got.Today)
	}
}

func TestTodayIsANairobiDayEvenWhenUTCDisagrees(t *testing.T) {
	h := newHarness(t)
	h.clock.Advance(13 * time.Hour) // 01:00 Tuesday in Nairobi, still Monday in UTC.
	rider := h.newUser(t, "rider")
	driver := h.newDriver(t, driverSpec{})
	seed := &testdb.Seeder{Pool: h.pool}
	seed.Ride(t, testdb.Ride{Rider: rider, Driver: &driver, Status: "completed", FareKES: 400, Ended: h.clock.Now().Add(-30 * time.Minute)})
	got, err := h.rides.Earnings(t.Context(), driver)
	if err != nil {
		t.Fatalf("Earnings: %v", err)
	}
	if got.Today.TotalKES != 400 {
		t.Errorf("today = %+v, want 400", got.Today)
	}
}

func TestSharedOfferDoesNotSingleOutOneRider(t *testing.T) {
	h := newHarness(t)
	_, first := h.bookShared(t, pickup, dropoff)
	_, second := h.bookShared(t, along(0.02), along(0.98))
	for _, rider := range []uuid.UUID{first, second} {
		h.exec(t, `UPDATE users SET rating_centi = 350, rating_count = 12 WHERE id = $1`, rider)
	}
	driver := h.newDriver(t, driverSpec{category: "basic"})
	h.runDue(t)
	offers := h.offers(t, driver)
	if len(offers) != 1 {
		t.Fatalf("offers = %d, want 1", len(offers))
	}
	if offers[0].RiderRating != nil {
		t.Errorf("shared offer rated one rider: %v", *offers[0].RiderRating)
	}
}
