package rides

import (
	"math"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
)

const (
	sharedMaxPickupM    = 2_500.0
	sharedMaxDropoffM   = 5_000.0
	sharedMaxCorridorM  = 1_200.0
	sharedMinProgress   = 0.02
	sharedMaxAge        = 30 * time.Minute
	sharedMaxExtraM     = 2_000.0
	sharedMaxExtraRatio = 0.6
	sharedMaxMembers    = 2

	sharedDiscountBps = 1_140
	sharedFloorBps    = 8_000

	metresPerDegree = 111_320.0
)

// sharedLeg is one passenger's trip.
type sharedLeg struct {
	pickup, dropoff geo.Point
}

// project maps a point onto the straight line of a trip. It returns how far
// along the trip it falls, from 0 to 1, and how far off the line it is.
func project(leg sharedLeg, p geo.Point) (progress, offM float64) {
	cosLat := math.Cos(leg.pickup.Lat * math.Pi / 180)
	dx := (leg.dropoff.Lng - leg.pickup.Lng) * cosLat * metresPerDegree
	dy := (leg.dropoff.Lat - leg.pickup.Lat) * metresPerDegree
	px := (p.Lng - leg.pickup.Lng) * cosLat * metresPerDegree
	py := (p.Lat - leg.pickup.Lat) * metresPerDegree
	length := dx*dx + dy*dy
	if length == 0 {
		return 0, math.Hypot(px, py)
	}
	t := min(max((px*dx+py*dy)/length, 0), 1)
	return t, math.Hypot(px-t*dx, py-t*dy)
}

// compatibility scores adding request to an existing trip, or reports false.
func compatibility(existing, request sharedLeg, age time.Duration) (float64, bool) {
	pickupM := geo.DistanceM(existing.pickup, request.pickup)
	dropoffM := geo.DistanceM(existing.dropoff, request.dropoff)
	if pickupM > sharedMaxPickupM || dropoffM > sharedMaxDropoffM || age > sharedMaxAge {
		return 0, false
	}
	pickupProgress, pickupOff := project(existing, request.pickup)
	dropoffProgress, dropoffOff := project(existing, request.dropoff)
	if pickupOff > sharedMaxCorridorM || dropoffOff > sharedMaxCorridorM {
		return 0, false
	}
	// Someone heading back the way the trip came is not going the same way.
	if dropoffProgress-pickupProgress < sharedMinProgress {
		return 0, false
	}
	freshness := 1 - float64(age)/float64(sharedMaxAge)
	return (1-pickupM/sharedMaxPickupM)*0.55 + (1-dropoffM/sharedMaxDropoffM)*0.35 + freshness*0.10, true
}

// stop is one place the driver must go.
type stop struct {
	leg    int
	pickup bool
	point  geo.Point
}

// planStops orders the stops nearest first, never dropping someone off before
// they are picked up. picked says which legs are already on board.
func planStops(start geo.Point, legs []sharedLeg, picked []bool) []stop {
	pending := make([]stop, 0, len(legs)*2)
	for i, leg := range legs {
		if !picked[i] {
			pending = append(pending, stop{leg: i, pickup: true, point: leg.pickup})
		}
		pending = append(pending, stop{leg: i, point: leg.dropoff})
	}
	onBoard := append([]bool(nil), picked...)
	plan := make([]stop, 0, len(pending))
	current := start
	for len(pending) > 0 {
		best, bestDistance := -1, math.Inf(1)
		for i, s := range pending {
			if !s.pickup && !onBoard[s.leg] {
				continue
			}
			if d := geo.DistanceM(current, s.point); d < bestDistance {
				best, bestDistance = i, d
			}
		}
		chosen := pending[best]
		if chosen.pickup {
			onBoard[chosen.leg] = true
		}
		plan = append(plan, chosen)
		current = chosen.point
		pending = append(pending[:best], pending[best+1:]...)
	}
	return plan
}

func planDistance(start geo.Point, plan []stop) float64 {
	total, current := 0.0, start
	for _, s := range plan {
		total += geo.DistanceM(current, s.point)
		current = s.point
	}
	return total
}

// detourAcceptable refuses a passenger who would drag the others too far.
func detourAcceptable(start geo.Point, current []sharedLeg, joining sharedLeg) bool {
	before := planDistance(start, planStops(start, current, make([]bool, len(current))))
	all := append(append([]sharedLeg(nil), current...), joining)
	after := planDistance(start, planStops(start, all, make([]bool, len(all))))
	extra := max(after-before, 0)
	ratio := 0.0
	if before > 1 {
		ratio = extra / before
	}
	return extra <= sharedMaxExtraM && ratio <= sharedMaxExtraRatio
}

// PriceShared applies the shared discount to a solo fare, never going below the
// floor. The discount is fixed here: the old system let the app send the inputs.
func PriceShared(solo Fare, rates Rates) Fare {
	fare := solo
	cents := int64(solo.FinalKES) * centsPerKES
	discounted := roundToTenKES(divideRound(cents*(bpsOne-sharedDiscountBps), bpsOne))
	floor := roundToTenKES(divideRound(rates.MinFareCents*sharedFloorBps, bpsOne))
	fare.FinalKES = toKES(max(discounted, floor))
	fare.DiscountKES = solo.BaseFareKES - fare.FinalKES
	return fare
}
