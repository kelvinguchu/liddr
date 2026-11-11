package dispatch_test

import (
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

// along returns a point the given fraction of the way from pickup to dropoff.
func along(fraction float64) geo.Point {
	return geo.Point{Lat: pickup.Lat + (dropoff.Lat-pickup.Lat)*fraction, Lng: pickup.Lng + (dropoff.Lng-pickup.Lng)*fraction}
}

func (h *harness) bookShared(t *testing.T, from, to geo.Point) (rides.Ride, uuid.UUID) {
	t.Helper()
	rider := h.newUser(t, "rider")
	quote, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: "basic", Pickup: from, Dropoff: to, Shared: true})
	if err != nil {
		t.Fatalf("CreateQuote: %v", err)
	}
	ride, err := h.rides.Book(t.Context(), rider, quote.ID)
	if err != nil {
		t.Fatalf("Book: %v", err)
	}
	return ride, rider
}

// group books two compatible riders onto one ride, and accepts it with a driver.
func (h *harness) group(t *testing.T) (ride uuid.UUID, first, second, driver uuid.UUID) {
	t.Helper()
	a, first := h.bookShared(t, pickup, dropoff)
	b, second := h.bookShared(t, along(0.02), along(0.98))
	if a.ID != b.ID {
		t.Fatalf("riders were not matched: %s and %s", a.ID, b.ID)
	}
	driver = h.newDriver(t, driverSpec{category: "basic"})
	h.runDue(t)
	offers := h.offers(t, driver)
	if len(offers) != 1 {
		t.Fatalf("offers = %v", offers)
	}
	if _, err := h.dispatch.Accept(t.Context(), driver, offers[0].ID); err != nil {
		t.Fatalf("Accept: %v", err)
	}
	return a.ID, first, second, driver
}

func (h *harness) memberOf(t *testing.T, ride, rider uuid.UUID) uuid.UUID {
	t.Helper()
	trip, err := h.rides.Shared(t.Context(), ride, rider)
	if err != nil {
		t.Fatalf("Shared: %v", err)
	}
	for _, m := range trip.Members {
		if m.IsSelf {
			return m.ID
		}
	}
	t.Fatal("rider is not a member")
	return uuid.Nil
}

func (h *harness) memberStatus(t *testing.T, id uuid.UUID) string {
	t.Helper()
	var status string
	if err := h.pool.QueryRow(t.Context(), `SELECT status FROM shared_members WHERE id = $1`, id).Scan(&status); err != nil {
		t.Fatalf("read member: %v", err)
	}
	return status
}

// board brings one passenger on, moving the driver to their pickup.
func (h *harness) board(t *testing.T, ride, member, driver uuid.UUID, at geo.Point) {
	t.Helper()
	h.moveDriver(t, driver, at)
	if err := h.rides.ArriveMember(t.Context(), ride, member, driver); err != nil {
		t.Fatalf("ArriveMember: %v", err)
	}
	if err := h.rides.PickUpMember(t.Context(), ride, member, driver); err != nil {
		t.Fatalf("PickUpMember: %v", err)
	}
}

func TestSharedQuotes(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	for _, category := range []string{"motorbike", "send"} {
		_, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: category, Pickup: pickup, Dropoff: dropoff, Shared: true})
		if !errors.Is(err, rides.ErrSharedNotAvailable) {
			t.Errorf("shared %s = %v", category, err)
		}
	}
	quote, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: "basic", Pickup: pickup, Dropoff: dropoff, Shared: true})
	if err != nil || quote.SoloFareKES == nil || quote.Fare.FinalKES >= *quote.SoloFareKES {
		t.Errorf("quote = %+v, %v", quote, err)
	}
}

func TestMatching(t *testing.T) {
	t.Run("the third rider gets their own trip", func(t *testing.T) {
		h := newHarness(t)
		a, _ := h.bookShared(t, pickup, dropoff)
		h.bookShared(t, along(0.02), along(0.98))
		c, _ := h.bookShared(t, along(0.03), along(0.97))
		if c.ID == a.ID {
			t.Error("a third rider joined a group of two")
		}
	})
	t.Run("the group locks once a driver accepts", func(t *testing.T) {
		h := newHarness(t)
		ride, _, _, _ := h.group(t)
		later, _ := h.bookShared(t, along(0.02), along(0.98))
		if later.ID == ride {
			t.Error("a rider joined after acceptance")
		}
	})
	t.Run("a rider in a group cannot book another trip", func(t *testing.T) {
		h := newHarness(t)
		h.bookShared(t, pickup, dropoff)
		_, joiner := h.bookShared(t, along(0.02), along(0.98))
		if _, err := h.rides.Book(t.Context(), joiner, h.quote(t, joiner).ID); !errors.Is(err, rides.ErrActiveRideExists) {
			t.Errorf("Book = %v", err)
		}
	})
	t.Run("retrying a join returns the same trip", func(t *testing.T) {
		h := newHarness(t)
		a, _ := h.bookShared(t, pickup, dropoff)
		rider := h.newUser(t, "rider")
		quote, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: "basic", Pickup: along(0.02), Dropoff: along(0.98), Shared: true})
		if err != nil {
			t.Fatalf("CreateQuote: %v", err)
		}
		for range 2 {
			got, err := h.rides.Book(t.Context(), rider, quote.ID)
			if err != nil || got.ID != a.ID {
				t.Errorf("Book = %+v, %v", got, err)
			}
		}
	})
}

func TestSharedTripFromStartToFinish(t *testing.T) {
	h := newHarness(t)
	ride, first, second, driver := h.group(t)
	m1, m2 := h.memberOf(t, ride, first), h.memberOf(t, ride, second)

	h.moveDriver(t, driver, pickup)
	if _, err := h.rides.MarkArrived(t.Context(), ride, driver); err != nil {
		t.Fatalf("MarkArrived: %v", err)
	}
	if _, err := h.rides.StartTrip(t.Context(), ride, driver); !errors.Is(err, rides.ErrMemberNotOnBoard) {
		t.Errorf("start with nobody aboard = %v", err)
	}
	h.moveDriver(t, driver, near(2000))
	if err := h.rides.ArriveMember(t.Context(), ride, m1, driver); !errors.Is(err, rides.ErrTooFarFromPickup) {
		t.Errorf("arrive from far away = %v", err)
	}
	h.board(t, ride, m1, driver, pickup)
	if _, err := h.rides.StartTrip(t.Context(), ride, driver); err != nil {
		t.Fatalf("StartTrip: %v", err)
	}
	h.board(t, ride, m2, driver, along(0.02))

	if _, err := h.rides.CompleteTrip(t.Context(), ride, driver, "cash_direct"); !errors.Is(err, rides.ErrMembersPending) {
		t.Errorf("complete with passengers aboard = %v", err)
	}
	h.moveDriver(t, driver, near(2000))
	if err := h.rides.DropOffMember(t.Context(), ride, m1, driver); !errors.Is(err, rides.ErrTooFarFromDropoff) {
		t.Errorf("drop off from far away = %v", err)
	}
	h.moveDriver(t, driver, along(0.98))
	if err := h.rides.DropOffMember(t.Context(), ride, m2, driver); err != nil {
		t.Fatalf("DropOffMember: %v", err)
	}
	seen, err := h.rides.Get(t.Context(), ride, second)
	if err != nil || seen.DriverLocation != nil {
		t.Errorf("a dropped-off passenger still sees the driver: %+v, %v", seen, err)
	}
	if seen, err := h.rides.Get(t.Context(), ride, first); err != nil || seen.DriverLocation == nil {
		t.Errorf("a passenger aboard lost the driver: %+v, %v", seen, err)
	}
	h.moveDriver(t, driver, dropoff)
	if err := h.rides.DropOffMember(t.Context(), ride, m1, driver); err != nil {
		t.Fatalf("DropOffMember: %v", err)
	}
	if _, err := h.rides.CompleteTrip(t.Context(), ride, driver, "cash_direct"); err != nil {
		t.Fatalf("CompleteTrip: %v", err)
	}
	var actions int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM rating_actions WHERE ride_id = $1`, ride).Scan(&actions); err != nil || actions != 3 {
		t.Errorf("rating invitations = %d, %v, want 3", actions, err)
	}
}

func TestPassengersSeeOnlyTheirOwnTrip(t *testing.T) {
	h := newHarness(t)
	ride, first, _, driver := h.group(t)
	mine, err := h.rides.Shared(t.Context(), ride, first)
	if err != nil {
		t.Fatalf("Shared: %v", err)
	}
	if len(mine.Stops) != 2 || mine.EarningsKES != nil {
		t.Errorf("passenger view = %+v", mine)
	}
	for _, m := range mine.Members {
		if !m.IsSelf && m.FareKES != nil {
			t.Errorf("passenger can see the other fare: %+v", m)
		}
	}
	theirs, err := h.rides.Shared(t.Context(), ride, driver)
	if err != nil || len(theirs.Stops) != 4 || theirs.EarningsKES == nil {
		t.Errorf("driver view = %+v, %v", theirs, err)
	}
	if _, err := h.rides.Shared(t.Context(), ride, h.newUser(t, "rider")); !errors.Is(err, rides.ErrRideNotFound) {
		t.Errorf("stranger = %v", err)
	}
}
