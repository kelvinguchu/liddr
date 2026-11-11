package rides

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	nairobiOffset  = 3 * time.Hour
	earningsDayMax = 7
)

// EarningsPeriod totals a span of completed trips.
type EarningsPeriod struct {
	Trips    int32
	TotalKES int32
}

// EarningsDay is one Nairobi day with at least one completed trip.
type EarningsDay struct {
	Date time.Time
	EarningsPeriod
}

// Earnings summarizes what a driver has earned. Weeks start on Monday, as
// subscription weeks do.
type Earnings struct {
	Today EarningsPeriod
	Week  EarningsPeriod
	Days  []EarningsDay
}

// Earnings returns the driver's totals for today, this week and the last
// seven days.
func (s *Service) Earnings(ctx context.Context, driverID uuid.UUID) (Earnings, error) {
	local := s.now().UTC().Add(nairobiOffset)
	today := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
	monday := today.AddDate(0, 0, -(int(today.Weekday())+6)%7)
	since := today.AddDate(0, 0, 1-earningsDayMax).Add(-nairobiOffset)

	rows, err := s.queries.SummarizeDriverEarnings(ctx, store.SummarizeDriverEarningsParams{DriverID: new(driverID), Since: new(since)})
	if err != nil {
		return Earnings{}, fmt.Errorf("summarize earnings: %w", err)
	}
	out := Earnings{Days: make([]EarningsDay, len(rows))}
	for i, row := range rows {
		period := EarningsPeriod{Trips: row.Trips, TotalKES: row.TotalKes}
		out.Days[i] = EarningsDay{Date: row.Day, EarningsPeriod: period}
		if row.Day.Equal(today) {
			out.Today = period
		}
		if !row.Day.Before(monday) {
			out.Week.Trips += period.Trips
			out.Week.TotalKES += period.TotalKES
		}
	}
	return out, nil
}
