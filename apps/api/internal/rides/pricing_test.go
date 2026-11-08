package rides

import (
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

var motorbike = Rates{Slug: "motorbike", BaseFeeCents: 2_000, PerKmCents: 1_500, PerMinCents: 300, MinFareCents: 12_000, DiscountBps: 1_500}

func TestPriceTrip(t *testing.T) {
	send := Rates{Slug: "send", BaseFeeCents: 2_500, PerKmCents: 1_600, PerMinCents: 300, MinFareCents: 15_000, DiscountBps: 1_500}
	tests := []struct {
		name                 string
		rates                Rates
		distanceM, durationS int32
		surgeBps             int32
		want                 Fare
	}{
		{
			// 20 + (4 x 15) + (1 x 15 x 0.96) + (15 x 3) = 139.40, rounds to 140, less 15% is 119, rounds to 120.
			name: "crosses first distance band", rates: motorbike, distanceM: 5_000, durationS: 900, surgeBps: 10_000,
			want: Fare{SurgeBps: 10_000, SubtotalCents: 13_940, BaseFareKES: 140, DiscountKES: 20, FinalKES: 120},
		},
		{
			name: "minimum fare applies", rates: motorbike, distanceM: 500, durationS: 60, surgeBps: 10_000,
			want: Fare{SurgeBps: 10_000, SubtotalCents: 12_000, BaseFareKES: 120, DiscountKES: 20, FinalKES: 100},
		},
		{
			name: "surge multiplies after minimum", rates: motorbike, distanceM: 500, durationS: 60, surgeBps: 15_000,
			want: Fare{SurgeBps: 15_000, SubtotalCents: 12_000, BaseFareKES: 180, DiscountKES: 30, FinalKES: 150},
		},
		{
			// 25 + (3 x 16) + (2 x 16 x 1.05) + (10 x 3) = 136.60, below the 150 minimum.
			name: "send distance gets dearer", rates: send, distanceM: 5_000, durationS: 600, surgeBps: 10_000,
			want: Fare{SurgeBps: 10_000, SubtotalCents: 15_000, BaseFareKES: 150, DiscountKES: 20, FinalKES: 130},
		},
		{
			// 20 + 60 + (8 x 15 x .96) + (8 x 15 x .92) + (20 x 3) + (25 x 3 x .95) + (15 x 3 x .9) = 477.35
			name: "all bands used", rates: motorbike, distanceM: 20_000, durationS: 3_600, surgeBps: 10_000,
			want: Fare{SurgeBps: 10_000, SubtotalCents: 47_735, BaseFareKES: 480, DiscountKES: 70, FinalKES: 410},
		},
		{
			name: "zero length trip", rates: motorbike, surgeBps: 10_000,
			want: Fare{SurgeBps: 10_000, SubtotalCents: 12_000, BaseFareKES: 120, DiscountKES: 20, FinalKES: 100},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := PriceTrip(tt.rates, tt.distanceM, tt.durationS, tt.surgeBps)
			if diff := cmp.Diff(got, tt.want); diff != "" {
				t.Errorf("fare mismatch (-got +want):\n%s", diff)
			}
		})
	}
}

func eat(day, hour, minute int) time.Time {
	return time.Date(2026, time.November, day, hour, minute, 0, 0, nairobi)
}

func TestTimeMultiplier(t *testing.T) {
	// 2 November 2026 is a Monday; 6 is a Friday, 7 Saturday, 8 Sunday.
	tests := []struct {
		name string
		at   time.Time
		want int32
	}{
		{"before dawn", eat(2, 4, 59), 12_500},
		{"early", eat(2, 5, 0), 10_500},
		{"morning peak", eat(2, 8, 0), 11_800},
		{"midday", eat(2, 12, 0), 10_000},
		{"evening peak", eat(2, 18, 0), 12_200},
		{"late evening", eat(2, 21, 0), 10_800},
		{"friday night", eat(6, 22, 0), 11_800},
		{"thursday night is no weekend", eat(5, 22, 0), 10_800},
		{"saturday small hours", eat(7, 3, 0), 13_500},
		{"sunday small hours", eat(8, 3, 59), 13_500},
		{"utc input is converted", time.Date(2026, 11, 2, 5, 0, 0, 0, time.UTC), 11_800},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := timeMultiplierBps(tt.at); got != tt.want {
				t.Errorf("timeMultiplierBps = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestDemandMultiplier(t *testing.T) {
	tests := []struct {
		name                 string
		available, searching int64
		want                 int32
	}{
		{"nobody around", 0, 0, 10_000},
		{"no drivers", 0, 1, 15_500},
		{"at 0.8", 10, 8, 10_000},
		{"just over 0.8", 10, 9, 10_500},
		{"at 1.2", 10, 12, 10_500},
		{"at 1.5", 10, 15, 11_200},
		{"at 2", 10, 20, 12_500},
		{"at 3", 10, 30, 14_000},
		{"beyond 3", 10, 31, 15_500},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := demandMultiplierBps(tt.available, tt.searching); got != tt.want {
				t.Errorf("demandMultiplierBps = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestSurgeIsCappedPerCategory(t *testing.T) {
	// Evening peak of 1.22 with maximum demand of 1.55 is 1.89 uncapped.
	peak := eat(2, 18, 0)
	if got := SurgeBps("motorbike", peak, 0, 5); got != 17_000 {
		t.Errorf("motorbike = %d, want 17000", got)
	}
	if got := SurgeBps("comfort", peak, 0, 5); got != 18_900 {
		t.Errorf("comfort = %d, want 18900", got)
	}
	if got := SurgeBps("basic", eat(2, 12, 0), 10, 0); got != 10_000 {
		t.Errorf("midday with no demand = %d, want 10000", got)
	}
}
