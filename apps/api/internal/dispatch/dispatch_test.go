package dispatch_test

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestOffersGoToNearestThree(t *testing.T) {
	h := newHarness(t)
	far := h.newDriver(t, driverSpec{at: near(2000)})
	first := h.newDriver(t, driverSpec{at: near(100)})
	second := h.newDriver(t, driverSpec{at: near(300)})
	third := h.newDriver(t, driverSpec{at: near(500)})
	h.book(t, h.newUser(t, "rider"))
	h.runDue(t)

	for _, driver := range []uuid.UUID{first, second, third} {
		if got := len(h.offers(t, driver)); got != 1 {
			t.Errorf("near driver has %d offers, want 1", got)
		}
	}
	if got := len(h.offers(t, far)); got != 0 {
		t.Errorf("fourth driver has %d offers, want 0", got)
	}
}

func TestIneligibleDriversGetNoOffers(t *testing.T) {
	tests := map[string]driverSpec{
		"offline":            {offline: true},
		"unverified":         {verification: "pending"},
		"no subscription":    {subscription: "inactive"},
		"suspended":          {subscription: "suspended"},
		"wrong category":     {category: "basic"},
		"banned account":     {account: "banned"},
		"restricted account": {account: "restricted"},
		"stale location":     {locationAge: 31 * time.Second},
		"outside max radius": {at: near(20_000)},
	}
	for name, spec := range tests {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			driver := h.newDriver(t, spec)
			h.book(t, h.newUser(t, "rider"))
			h.runDue(t)
			if got := len(h.offers(t, driver)); got != 0 {
				t.Errorf("offers = %d, want 0", got)
			}
		})
	}
}

func TestSearchWidensAfterEmptyWave(t *testing.T) {
	h := newHarness(t)
	h.book(t, h.newUser(t, "rider"))
	driver := h.newDriver(t, driverSpec{at: near(5000), locationAge: 0})
	h.runDue(t)
	if got := len(h.offers(t, driver)); got != 0 {
		t.Fatalf("first wave offered beyond 3.5km: %d", got)
	}
	h.clock.Advance(10 * time.Second)
	h.moveDriver(t, driver, near(5000))
	h.runDue(t)
	if got := len(h.offers(t, driver)); got != 1 {
		t.Errorf("second wave offers = %d, want 1 at 1.5x radius", got)
	}
}

func TestDriverHoldsOneOpenOffer(t *testing.T) {
	h := newHarness(t)
	driver := h.newDriver(t, driverSpec{})
	h.book(t, h.newUser(t, "rider"))
	h.book(t, h.newUser(t, "rider"))
	h.runDue(t)
	if got := len(h.offers(t, driver)); got != 1 {
		t.Errorf("open offers = %d, want 1", got)
	}
}

func TestExpiredOfferMovesToNextDriverAndNeverRepeats(t *testing.T) {
	h := newHarness(t)
	first := h.newDriver(t, driverSpec{at: near(100)})
	h.book(t, h.newUser(t, "rider"))
	h.runDue(t)

	h.clock.Advance(15 * time.Second)
	h.moveDriver(t, first, near(100))
	second := h.newDriver(t, driverSpec{at: near(150)})
	h.runDue(t)

	if got := len(h.offers(t, first)); got != 0 {
		t.Errorf("first driver re-offered: %d", got)
	}
	if got := len(h.offers(t, second)); got != 1 {
		t.Errorf("second driver offers = %d, want 1", got)
	}
}

func TestRejectBringsNextWaveForward(t *testing.T) {
	h := newHarness(t)
	first := h.newDriver(t, driverSpec{at: near(100)})
	h.book(t, h.newUser(t, "rider"))
	h.runDue(t)
	second := h.newDriver(t, driverSpec{at: near(150)})

	if err := h.dispatch.Reject(t.Context(), first, h.offers(t, first)[0].ID); err != nil {
		t.Fatalf("Reject: %v", err)
	}
	h.runDue(t)
	if got := len(h.offers(t, second)); got != 1 {
		t.Errorf("second driver offers = %d, want 1 without waiting", got)
	}
}

// The legacy dispatcher kept this state in memory and retried forever.
func TestSearchEndsAfterThreeMinutesAndSurvivesRestart(t *testing.T) {
	h := newHarness(t)
	ride := h.book(t, h.newUser(t, "rider"))
	h.runDue(t)

	h.clock.Advance(90 * time.Second)
	h.runDue(t)
	if got := h.status(t, ride.ID); got != rides.StatusSearching {
		t.Fatalf("status = %q, want searching", got)
	}

	restarted := dispatch.NewService(dispatch.Config{Pool: h.pool, Now: h.clock.Now})
	h.clock.Advance(90 * time.Second)
	if err := restarted.RunDue(t.Context()); err != nil {
		t.Fatalf("RunDue: %v", err)
	}
	if got := h.status(t, ride.ID); got != rides.StatusNoDrivers {
		t.Errorf("status = %q, want no_drivers", got)
	}
}

func TestAcceptAssignsRideAndWithdrawsOthers(t *testing.T) {
	h := newHarness(t)
	winner := h.newDriver(t, driverSpec{at: near(100)})
	loser := h.newDriver(t, driverSpec{at: near(200)})
	ride := h.book(t, h.newUser(t, "rider"))
	h.runDue(t)
	loserOffer := h.offers(t, loser)[0].ID

	rideID, err := h.dispatch.Accept(t.Context(), winner, h.offers(t, winner)[0].ID)
	if err != nil {
		t.Fatalf("Accept: %v", err)
	}
	if rideID != ride.ID || h.status(t, ride.ID) != rides.StatusAccepted {
		t.Errorf("ride = %v, status = %q", rideID, h.status(t, ride.ID))
	}
	// A rival's offer left open would block that driver from all future offers.
	if got := len(h.offers(t, loser)); got != 0 {
		t.Errorf("rival still has %d open offers", got)
	}
	var open int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM ride_offers WHERE status = 'offered'`).Scan(&open); err != nil {
		t.Fatalf("count open offers: %v", err)
	}
	if open != 0 {
		t.Errorf("open offers = %d, want 0", open)
	}
	if _, err := h.dispatch.Accept(t.Context(), loser, loserOffer); !errors.Is(err, dispatch.ErrOfferClosed) {
		t.Errorf("late accept = %v, want ErrOfferClosed", err)
	}
}

func TestConcurrentAcceptsHaveOneWinner(t *testing.T) {
	h := newHarness(t)
	drivers := []uuid.UUID{h.newDriver(t, driverSpec{at: near(100)}), h.newDriver(t, driverSpec{at: near(120)}), h.newDriver(t, driverSpec{at: near(140)})}
	ride := h.book(t, h.newUser(t, "rider"))
	h.runDue(t)
	offers := make([]uuid.UUID, len(drivers))
	for i, driver := range drivers {
		offers[i] = h.offers(t, driver)[0].ID
	}

	var wins atomic.Int32
	var wg sync.WaitGroup
	for i := range drivers {
		wg.Go(func() {
			_, err := h.dispatch.Accept(t.Context(), drivers[i], offers[i])
			switch {
			case err == nil:
				wins.Add(1)
			case !errors.Is(err, dispatch.ErrOfferClosed):
				t.Errorf("Accept = %v", err)
			}
		})
	}
	wg.Wait()
	if got := wins.Load(); got != 1 {
		t.Errorf("winners = %d, want 1", got)
	}
	if got := h.status(t, ride.ID); got != rides.StatusAccepted {
		t.Errorf("status = %q", got)
	}
}

func TestAcceptRejections(t *testing.T) {
	setup := func(t *testing.T) (*harness, uuid.UUID, uuid.UUID, rides.Ride, uuid.UUID) {
		h := newHarness(t)
		driver := h.newDriver(t, driverSpec{})
		rider := h.newUser(t, "rider")
		ride := h.book(t, rider)
		h.runDue(t)
		return h, driver, h.offers(t, driver)[0].ID, ride, rider
	}
	t.Run("expired", func(t *testing.T) {
		h, driver, offer, _, _ := setup(t)
		h.clock.Advance(15 * time.Second)
		if _, err := h.dispatch.Accept(t.Context(), driver, offer); !errors.Is(err, dispatch.ErrOfferClosed) {
			t.Errorf("Accept = %v, want ErrOfferClosed", err)
		}
	})
	t.Run("another driver's offer", func(t *testing.T) {
		h, _, offer, _, _ := setup(t)
		other := h.newDriver(t, driverSpec{offline: true})
		if _, err := h.dispatch.Accept(t.Context(), other, offer); !errors.Is(err, dispatch.ErrOfferNotFound) {
			t.Errorf("Accept = %v, want ErrOfferNotFound", err)
		}
	})
	t.Run("subscription lapsed after offer", func(t *testing.T) {
		h, driver, offer, _, _ := setup(t)
		h.exec(t, `UPDATE drivers SET subscription_status = 'suspended' WHERE user_id = $1`, driver)
		if _, err := h.dispatch.Accept(t.Context(), driver, offer); !errors.Is(err, dispatch.ErrSubscriptionNeeded) {
			t.Errorf("Accept = %v, want ErrSubscriptionNeeded", err)
		}
	})
	t.Run("rider cancelled first", func(t *testing.T) {
		h, driver, offer, ride, rider := setup(t)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		if _, err := h.dispatch.Accept(t.Context(), driver, offer); !errors.Is(err, dispatch.ErrOfferClosed) {
			t.Errorf("Accept = %v, want ErrOfferClosed", err)
		}
	})
}
