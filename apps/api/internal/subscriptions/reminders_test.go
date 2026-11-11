package subscriptions_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
)

func (h *harness) activeWeek(t *testing.T, driver uuid.UUID, start time.Time, status string) {
	t.Helper()
	h.exec(t, `INSERT INTO subscriptions (id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, created_at)
		SELECT $1, $2, vehicle_category_id, $3, $4, 1000, $5, $6, now() FROM drivers WHERE user_id = $2`,
		uuid.New(), driver, start, start.AddDate(0, 0, 6), status, fmt.Sprintf("R%d", h.nextPhone.Add(1)))
}

func (h *harness) reminders(t *testing.T, driver uuid.UUID) string {
	t.Helper()
	return h.scalar(t, `SELECT count(*)::text FROM notifications WHERE user_id = $1 AND event_type = 'subscription.renewal' AND status = 'expiring'`, driver)
}

func TestRenewalReminderGoesOutOnceFromSundayEvening(t *testing.T) {
	monday := time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC)
	eight := time.Date(2026, 11, 15, 17, 0, 0, 0, time.UTC) // Sunday 20:00 in Nairobi.
	tests := []struct {
		name   string
		at     time.Time
		status string
		paid   bool
		want   string
	}{
		{name: "before eight", at: eight.Add(-time.Minute), status: "active", want: "0"},
		{name: "at eight", at: eight, status: "active", want: "1"},
		{name: "after a restart at eleven", at: eight.Add(3 * time.Hour), status: "active", want: "1"},
		{name: "next morning is too late", at: eight.Add(7 * time.Hour), status: "active", want: "0"},
		{name: "saturday evening is a day early", at: eight.Add(-24 * time.Hour), status: "active", want: "0"},
		{name: "next week already paid", at: eight, status: "active", paid: true, want: "0"},
		{name: "this week never paid", at: eight, status: "pending", want: "0"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			driver, _ := h.newDriver(t, "approved")
			h.activeWeek(t, driver, monday, tt.status)
			if tt.paid {
				h.activeWeek(t, driver, monday.AddDate(0, 0, 7), "active")
			}
			h.clock.Set(tt.at)
			for range 2 { // The second pass must not send it again.
				if err := h.svc.RemindRenewals(t.Context()); err != nil {
					t.Fatalf("RemindRenewals: %v", err)
				}
			}
			if got := h.reminders(t, driver); got != tt.want {
				t.Errorf("reminders = %s, want %s", got, tt.want)
			}
		})
	}
}
