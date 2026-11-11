package rides

import "math"

const (
	bpsOne         = 10_000
	centsPerKES    = 100
	fareRoundingKS = 10
	metresPerKm    = 1_000
	secondsPerMin  = 60
)

// Rates are a vehicle category's fare settings.
type Rates struct {
	Slug         string
	BaseFeeCents int64
	PerKmCents   int64
	PerMinCents  int64
	MinFareCents int64
	DiscountBps  int32
}

// Fare is a computed price.
type Fare struct {
	SurgeBps      int32
	SubtotalCents int64
	BaseFareKES   int32
	DiscountKES   int32
	FinalKES      int32
}

// band applies factorBps to units up to limit, which is cumulative. A limit of
// zero means the band has no end.
type band struct {
	limit     int64
	factorBps int64
}

// PriceTrip computes a fare using only integer arithmetic.
func PriceTrip(rates Rates, distanceM, durationS, surgeBps int32) Fare {
	distanceCents := divideRound(weightedUnits(int64(distanceM), distanceBands(rates.Slug))*rates.PerKmCents, metresPerKm*bpsOne)
	timeCents := divideRound(weightedUnits(int64(durationS), timeBands(rates.Slug))*rates.PerMinCents, secondsPerMin*bpsOne)

	subtotal := max(rates.BaseFeeCents+distanceCents+timeCents, rates.MinFareCents)
	baseFare := roundToTenKES(divideRound(subtotal*int64(surgeBps), bpsOne))
	finalFare := roundToTenKES(divideRound(baseFare*(bpsOne-int64(rates.DiscountBps)), bpsOne))

	return Fare{
		SurgeBps:      surgeBps,
		SubtotalCents: subtotal,
		BaseFareKES:   toKES(baseFare),
		DiscountKES:   toKES(baseFare - finalFare),
		FinalKES:      toKES(finalFare),
	}
}

func toKES(cents int64) int32 {
	return int32(min(cents/centsPerKES, math.MaxInt32)) //nolint:gosec // min bounds it to 32 bits.
}

// weightedUnits returns the sum of units times factor across bands.
func weightedUnits(units int64, bands []band) int64 {
	var total, consumed int64
	for _, b := range bands {
		if units <= consumed {
			break
		}
		upTo := units
		if b.limit > 0 {
			upTo = min(units, b.limit)
		}
		total += (upTo - consumed) * b.factorBps
		consumed = upTo
	}
	return total
}

func divideRound(numerator, denominator int64) int64 {
	return (numerator + denominator/2) / denominator
}

func roundToTenKES(cents int64) int64 {
	step := int64(fareRoundingKS * centsPerKES)
	return divideRound(cents, step) * step
}

func distanceBands(slug string) []band {
	switch slug {
	case "motorbike", "electric_motorbike":
		return []band{{4_000, 10_000}, {12_000, 9_600}, {0, 9_200}}
	case "send":
		return []band{{3_000, 10_000}, {10_000, 10_500}, {0, 11_200}}
	case "comfort":
		return []band{{6_000, 10_000}, {20_000, 9_400}, {0, 8_800}}
	case "xl":
		return []band{{6_000, 10_000}, {20_000, 10_000}, {0, 10_300}}
	default:
		return []band{{6_000, 10_000}, {20_000, 9_500}, {0, 9_000}}
	}
}

func timeBands(slug string) []band {
	switch slug {
	case "motorbike", "electric_motorbike":
		return []band{{1_200, 10_000}, {2_700, 9_500}, {0, 9_000}}
	case "send":
		return []band{{1_200, 10_000}, {2_700, 9_800}, {0, 9_500}}
	case "comfort":
		return []band{{1_200, 10_000}, {3_000, 9_400}, {0, 8_800}}
	case "xl":
		return []band{{1_200, 10_000}, {3_000, 10_000}, {0, 10_200}}
	default:
		return []band{{1_200, 10_000}, {3_000, 9_500}, {0, 9_000}}
	}
}
