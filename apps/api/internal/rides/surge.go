package rides

import "time"

const surgeRoundingBps = 100

var nairobi = time.FixedZone("EAT", 3*60*60)

// SurgeBps combines time of day and local demand, capped per category.
func SurgeBps(slug string, now time.Time, availableDrivers, searchingRides int64) int32 {
	combined := int64(timeMultiplierBps(now)) * int64(demandMultiplierBps(availableDrivers, searchingRides)) / bpsOne
	rounded := divideRound(combined, surgeRoundingBps) * surgeRoundingBps
	return int32(min(max(rounded, bpsOne), int64(maxSurgeBps(slug)))) //nolint:gosec // Bounded by the category cap.
}

func timeMultiplierBps(now time.Time) int32 {
	local := now.In(nairobi)
	minutes := local.Hour()*60 + local.Minute()

	var base int32
	switch {
	case minutes < 5*60:
		base = 12_500
	case minutes < 6*60+30:
		base = 10_500
	case minutes < 9*60+30:
		base = 11_800
	case minutes < 16*60+30:
		base = 10_000
	case minutes < 20*60+30:
		base = 12_200
	default:
		base = 10_800
	}
	if isWeekendLateNight(local.Weekday(), minutes) {
		return min(base+1_000, 13_500)
	}
	return base
}

func isWeekendLateNight(day time.Weekday, minutes int) bool {
	switch {
	case (day == time.Friday || day == time.Saturday) && minutes >= 22*60:
		return true
	case (day == time.Saturday || day == time.Sunday) && minutes < 4*60:
		return true
	default:
		return false
	}
}

// demandMultiplierBps compares searching rides to available drivers. Ratios are
// compared by cross-multiplying, to stay in integers.
func demandMultiplierBps(available, searching int64) int32 {
	if available == 0 {
		if searching > 0 {
			return 15_500
		}
		return bpsOne
	}
	tenths := searching * 10
	switch {
	case tenths <= available*8:
		return bpsOne
	case tenths <= available*12:
		return 10_500
	case tenths <= available*15:
		return 11_200
	case tenths <= available*20:
		return 12_500
	case tenths <= available*30:
		return 14_000
	default:
		return 15_500
	}
}

func maxSurgeBps(slug string) int32 {
	switch slug {
	case "motorbike", "electric_motorbike", "send":
		return 17_000
	case "comfort", "xl":
		return 20_000
	default:
		return 18_000
	}
}

func travelMode(slug string) string {
	if slug == "motorbike" || slug == "electric_motorbike" {
		return "TWO_WHEELER"
	}
	return "DRIVE"
}

func routingPreference(slug string) string {
	if slug == "motorbike" || slug == "electric_motorbike" {
		return "TRAFFIC_AWARE"
	}
	return "TRAFFIC_AWARE_OPTIMAL"
}
