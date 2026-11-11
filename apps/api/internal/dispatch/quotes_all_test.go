package dispatch_test

import (
	"errors"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

func TestQuoteAllSharesOneRoutePerTravelMode(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	quotes, err := h.rides.QuoteAll(t.Context(), rider, pickup, dropoff)
	if err != nil {
		t.Fatalf("QuoteAll: %v", err)
	}
	var got []string
	for _, q := range quotes {
		got = append(got, q.Category)
	}
	// The open categories in display order. Comfort, XL and the rest are inactive.
	if diff := cmp.Diff(got, []string{"motorbike", "electric_motorbike", "basic", "send"}); diff != "" {
		t.Errorf("categories (-got +want):\n%s", diff)
	}
	// Motorbikes route as two-wheelers and the rest as cars: two requests, not four.
	if calls := h.routeCalls.Load(); calls != 2 {
		t.Errorf("route requests = %d, want 2", calls)
	}
	single, err := h.rides.CreateQuote(t.Context(), rides.QuoteRequest{RiderID: rider, Category: "basic", Pickup: pickup, Dropoff: dropoff})
	if err != nil {
		t.Fatalf("CreateQuote: %v", err)
	}
	if quotes[2].Quote.Fare != single.Fare {
		t.Errorf("batch fare %+v differs from single fare %+v", quotes[2].Quote.Fare, single.Fare)
	}
	if _, err := h.rides.Book(t.Context(), rider, quotes[0].Quote.ID); err != nil {
		t.Errorf("Book a batch quote: %v", err)
	}
}

func TestQuoteAllCountsEveryQuoteTowardTheLimit(t *testing.T) {
	h := newHarness(t)
	rider := h.newUser(t, "rider")
	for range 5 { // 5 x 4 = 20, the limit.
		if _, err := h.rides.QuoteAll(t.Context(), rider, pickup, dropoff); err != nil {
			t.Fatalf("QuoteAll: %v", err)
		}
	}
	calls := h.routeCalls.Load()
	if _, err := h.rides.QuoteAll(t.Context(), rider, pickup, dropoff); !errors.Is(err, rides.ErrRateLimited) {
		t.Errorf("sixth QuoteAll = %v, want ErrRateLimited", err)
	}
	if h.routeCalls.Load() != calls {
		t.Error("a refused batch still paid for routing")
	}
}
