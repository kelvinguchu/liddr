package dispatch_test

import (
	"errors"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestQuoteUsesRouteAndCategoryRates(t *testing.T) {
	h := newHarness(t)
	quote := h.quote(t, h.newUser(t, "rider"))

	if quote.Fare.FinalKES != 120 || quote.Fare.BaseFareKES != 140 || quote.Fare.DiscountKES != 20 {
		t.Errorf("fare = %+v, want 120 after discount from 140", quote.Fare)
	}
	if quote.DistanceM != 5000 || quote.DurationS != 900 || quote.Polyline != "xyz" {
		t.Errorf("route = %+v", quote)
	}
	if want := h.clock.Now().Add(3 * time.Minute); !quote.ExpiresAt.Equal(want) {
		t.Errorf("ExpiresAt = %v, want %v", quote.ExpiresAt, want)
	}
}

func TestQuoteRejectsBadRequests(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	london := geo.Point{Lat: 51.5, Lng: -0.12}
	tests := []struct {
		name     string
		category string
		from, to geo.Point
		want     error
	}{
		{"pickup abroad", "motorbike", london, dropoff, rides.ErrOutsideServiceArea},
		{"dropoff abroad", "motorbike", pickup, london, rides.ErrOutsideServiceArea},
		{"not a number", "motorbike", geo.Point{Lat: math.NaN(), Lng: 36.8}, dropoff, rides.ErrOutsideServiceArea},
		{"out of range", "motorbike", geo.Point{Lat: 91, Lng: 36.8}, dropoff, rides.ErrOutsideServiceArea},
		{"unknown category", "helicopter", pickup, dropoff, rides.ErrCategoryNotFound},
		{"phase two category", "comfort", pickup, dropoff, rides.ErrCategoryNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: tt.category, Pickup: tt.from, Dropoff: tt.to})
			if !errors.Is(err, tt.want) {
				t.Errorf("CreateQuote = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestQuoteRateLimitProtectsPaidRouting(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	req := rides.QuoteRequest{RiderID: rider, Category: "motorbike", Pickup: pickup, Dropoff: dropoff}
	for range 20 {
		h.quote(t, rider)
	}
	if _, err := h.rides.CreateQuote(t.Context(), req); !errors.Is(err, rides.ErrRateLimited) {
		t.Errorf("21st quote = %v, want ErrRateLimited", err)
	}
	h.clock.Advance(time.Minute)
	h.quote(t, rider)
}

func TestQuoteSurfacesRoutingOutage(t *testing.T) {
	h := newHarness(t)
	h.routesDown.Store(true)
	_, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: h.newUser(t, "rider"), Category: "motorbike", Pickup: pickup, Dropoff: dropoff})
	if !errors.Is(err, rides.ErrRouteUnavailable) {
		t.Errorf("CreateQuote = %v, want ErrRouteUnavailable", err)
	}
}

func TestQuoteSurgesWithDemand(t *testing.T) {
	h := newHarness(t)
	h.book(t, h.newUser(t, "rider"))

	quote := h.quote(t, h.newUser(t, "rider"))
	if quote.Fare.SurgeBps != 15_500 {
		t.Errorf("surge = %d, want 15500 with one search and no drivers", quote.Fare.SurgeBps)
	}
}

func TestBookTakesFareAndRouteFromQuote(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	quote := h.quote(t, rider)

	ride, err := h.rides.Book(t.Context(), rider, quote.ID)
	if err != nil {
		t.Fatalf("Book: %v", err)
	}
	if ride.FareKES != quote.Fare.FinalKES || ride.Status != rides.StatusSearching {
		t.Errorf("ride = %+v", ride)
	}
	if ride.Pickup != pickup || ride.Dropoff != dropoff {
		t.Errorf("route = %v to %v", ride.Pickup, ride.Dropoff)
	}
}

func TestBookIsIdempotentUnderConcurrency(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	quote := h.quote(t, rider)

	var wg sync.WaitGroup
	ids := make([]uuid.UUID, 16)
	for i := range ids {
		wg.Go(func() {
			ride, err := h.rides.Book(t.Context(), rider, quote.ID)
			if err != nil {
				t.Errorf("Book: %v", err)
				return
			}
			ids[i] = ride.ID
		})
	}
	wg.Wait()

	for _, id := range ids {
		if id != ids[0] {
			t.Errorf("ids differ: %v and %v", id, ids[0])
		}
	}
	var count int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM rides`).Scan(&count); err != nil {
		t.Fatalf("count rides: %v", err)
	}
	if count != 1 {
		t.Errorf("rides = %d, want 1", count)
	}
}

func TestBookRejections(t *testing.T) {
	t.Run("someone else's quote", func(t *testing.T) {
		h := newHarness(t)
		quote := h.quote(t, h.newUser(t, "rider"))
		if _, err := h.rides.Book(t.Context(), h.newUser(t, "rider"), quote.ID); !errors.Is(err, rides.ErrQuoteNotFound) {
			t.Errorf("Book = %v, want ErrQuoteNotFound", err)
		}
	})
	t.Run("unknown quote", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.rides.Book(t.Context(), h.newUser(t, "rider"), uuid.New()); !errors.Is(err, rides.ErrQuoteNotFound) {
			t.Errorf("Book = %v, want ErrQuoteNotFound", err)
		}
	})
	t.Run("expired quote", func(t *testing.T) {
		h := newHarness(t)
		rider := h.newUser(t, "rider")
		quote := h.quote(t, rider)
		h.clock.Advance(3 * time.Minute)
		if _, err := h.rides.Book(t.Context(), rider, quote.ID); !errors.Is(err, rides.ErrQuoteExpired) {
			t.Errorf("Book = %v, want ErrQuoteExpired", err)
		}
	})
	t.Run("second active ride", func(t *testing.T) {
		h := newHarness(t)
		rider := h.newUser(t, "rider")
		h.book(t, rider)
		if _, err := h.rides.Book(t.Context(), rider, h.quote(t, rider).ID); !errors.Is(err, rides.ErrActiveRideExists) {
			t.Errorf("Book = %v, want ErrActiveRideExists", err)
		}
	})
}

func TestBookingHourlyLimit(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	for range 10 {
		ride := h.book(t, rider)
		if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
			t.Fatalf("Cancel: %v", err)
		}
		h.clock.Advance(4 * time.Second)
	}
	if _, err := h.rides.Book(t.Context(), rider, h.quote(t, rider).ID); !errors.Is(err, rides.ErrRateLimited) {
		t.Errorf("11th booking = %v, want ErrRateLimited", err)
	}
}
