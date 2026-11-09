package rides

import (
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
)

var (
	southA = geo.Point{Lat: -1.3000, Lng: 36.8000}
	northA = geo.Point{Lat: -1.2500, Lng: 36.8000}
	base   = sharedLeg{pickup: southA, dropoff: northA}
)

func offset(p geo.Point, northM, eastM float64) geo.Point {
	return geo.Point{Lat: p.Lat + northM/metresPerDegree, Lng: p.Lng + eastM/metresPerDegree}
}

func TestCompatibility(t *testing.T) {
	cases := []struct {
		name    string
		request sharedLeg
		age     time.Duration
		want    bool
	}{
		{"same corridor", sharedLeg{offset(southA, 300, 0), offset(northA, -300, 0)}, time.Minute, true},
		{"opposite direction", sharedLeg{offset(southA, 2000, 0), offset(southA, 1000, 0)}, time.Minute, false},
		{"pickup too far", sharedLeg{offset(southA, 3000, 0), northA}, time.Minute, false},
		{"off the route", sharedLeg{offset(southA, 500, 1500), offset(northA, -500, 1500)}, time.Minute, false},
		{"group too old", sharedLeg{offset(southA, 300, 0), offset(northA, -300, 0)}, 31 * time.Minute, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, ok := compatibility(base, tc.request, tc.age); ok != tc.want {
				t.Errorf("compatible = %v, want %v", ok, tc.want)
			}
		})
	}
}

func TestPlanStopsNeverDropsBeforePickup(t *testing.T) {
	legs := []sharedLeg{
		{southA, northA},
		{offset(southA, 4000, 0), offset(southA, 100, 0)},
	}
	plan := planStops(southA, legs, []bool{false, false})
	if len(plan) != 4 {
		t.Fatalf("plan = %+v", plan)
	}
	picked := map[int]bool{}
	for _, s := range plan {
		if s.pickup {
			picked[s.leg] = true
		} else if !picked[s.leg] {
			t.Errorf("leg %d dropped before pickup: %+v", s.leg, plan)
		}
	}
}

func TestDetourLimit(t *testing.T) {
	near := sharedLeg{offset(southA, 200, 0), offset(northA, -200, 0)}
	if !detourAcceptable(southA, []sharedLeg{base}, near) {
		t.Error("a passenger along the way was refused")
	}
	far := sharedLeg{offset(southA, 0, 2500), offset(northA, 0, 2500)}
	if detourAcceptable(southA, []sharedLeg{base}, far) {
		t.Error("a long detour was allowed")
	}
}

func TestPriceShared(t *testing.T) {
	rates := Rates{MinFareCents: 20_000}
	cases := []struct {
		name string
		solo int32
		want int32
	}{
		{"discount applies", 500, 440},
		{"never below the floor", 170, 160},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := PriceShared(Fare{FinalKES: tc.solo, BaseFareKES: tc.solo}, rates); got.FinalKES != tc.want {
				t.Errorf("fare = %d, want %d", got.FinalKES, tc.want)
			}
		})
	}
}
