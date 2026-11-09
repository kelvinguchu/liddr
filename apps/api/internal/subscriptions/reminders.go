package subscriptions

import (
	"context"
	"fmt"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const reminderHour = 20

// RemindRenewals tells drivers whose week ends tonight to renew. It runs from
// Sunday 8pm in Nairobi until midnight, so a restart cannot lose the reminder,
// and each paid week is reminded once.
func (s *Service) RemindRenewals(ctx context.Context) error {
	now := s.now()
	local := now.UTC().Add(3 * time.Hour)
	if local.Weekday() != time.Sunday || local.Hour() < reminderHour {
		return nil
	}
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		drivers, err := q.ClaimRenewalReminders(ctx, store.ClaimRenewalRemindersParams{Now: new(now), WeekStart: weekStart(now)})
		if err != nil {
			return fmt.Errorf("claim reminders: %w", err)
		}
		// One event each: a Postgres notification cannot carry a long recipient list.
		for _, driver := range drivers {
			if err := events.Notify(ctx, q, events.Event{Type: events.TypeSubscriptionRenewal, Status: "expiring"}, driver); err != nil {
				return fmt.Errorf("notify driver: %w", err)
			}
		}
		return nil
	})
}
