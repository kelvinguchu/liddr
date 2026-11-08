package dispatch_test

import (
	"errors"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
)

func TestLocationPings(t *testing.T) {
	h := newHarness(t)
	driver := h.newDriver(t, driverSpec{at: near(100)})
	moved := near(400)

	h.clock.Advance(time.Second)
	if err := h.dispatch.UpdateLocation(t.Context(), driver, moved); err != nil {
		t.Fatalf("excess ping = %v, want silent drop", err)
	}
	var lat float64
	read := func() float64 {
		if err := h.pool.QueryRow(t.Context(), `SELECT lat FROM driver_locations WHERE driver_id = $1`, driver).Scan(&lat); err != nil {
			t.Fatalf("read location: %v", err)
		}
		return lat
	}
	if got := read(); got == moved.Lat {
		t.Error("ping inside the three second limit was stored")
	}
	h.clock.Advance(3 * time.Second)
	if err := h.dispatch.UpdateLocation(t.Context(), driver, moved); err != nil {
		t.Fatalf("UpdateLocation: %v", err)
	}
	if got := read(); got != moved.Lat {
		t.Errorf("lat = %v, want %v", got, moved.Lat)
	}

	offline := h.newDriver(t, driverSpec{offline: true})
	if err := h.dispatch.UpdateLocation(t.Context(), offline, moved); !errors.Is(err, dispatch.ErrDriverOffline) {
		t.Errorf("offline driver = %v, want ErrDriverOffline", err)
	}
	if err := h.dispatch.UpdateLocation(t.Context(), driver, geo.Point{Lat: 200}); !errors.Is(err, dispatch.ErrInvalidLocation) {
		t.Errorf("bad point = %v, want ErrInvalidLocation", err)
	}
}

func TestGoOnlineGates(t *testing.T) {
	tests := []struct {
		name string
		spec driverSpec
		want error
	}{
		{"approved and paid", driverSpec{offline: true}, nil},
		{"grace period", driverSpec{offline: true, subscription: "grace"}, nil},
		{"unverified", driverSpec{offline: true, verification: "pending"}, dispatch.ErrNotVerified},
		{"unpaid", driverSpec{offline: true, subscription: "inactive"}, dispatch.ErrSubscriptionNeeded},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			if err := h.dispatch.GoOnline(t.Context(), h.newDriver(t, tt.spec)); !errors.Is(err, tt.want) {
				t.Errorf("GoOnline = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestCategoryLocksAfterApproval(t *testing.T) {
	h := newHarness(t)
	pending := h.newDriver(t, driverSpec{verification: "pending"})
	if _, err := h.dispatch.SetCategory(t.Context(), pending, "basic"); err != nil {
		t.Errorf("pending driver = %v, want nil", err)
	}
	approved := h.newDriver(t, driverSpec{})
	if _, err := h.dispatch.SetCategory(t.Context(), approved, "basic"); !errors.Is(err, dispatch.ErrCategoryLocked) {
		t.Errorf("approved driver = %v, want ErrCategoryLocked", err)
	}
}
