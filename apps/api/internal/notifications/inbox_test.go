package notifications_test

import (
	"errors"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
)

func TestInbox(t *testing.T) {
	w := newWorld(t)
	owner, other := w.user(t, "254711111111"), w.user(t, "254722222222")
	w.notify(t, events.TypeRideStatus, owner)
	items, err := w.service.List(t.Context(), owner, false, 0)
	if err != nil || len(items) != 1 {
		t.Fatalf("List = %v, %v", items, err)
	}
	if err := w.service.Ack(t.Context(), other, items[0].ID); !errors.Is(err, notifications.ErrNotFound) {
		t.Errorf("Ack by someone else = %v", err)
	}
	for range 2 {
		if err := w.service.Ack(t.Context(), owner, items[0].ID); err != nil {
			t.Errorf("Ack = %v", err)
		}
	}
	if count, err := w.service.UnreadCount(t.Context(), owner); err != nil || count != 0 {
		t.Errorf("UnreadCount = %d, %v", count, err)
	}
	if acked, err := w.service.List(t.Context(), owner, true, 0); err != nil || len(acked) != 1 {
		t.Errorf("List including read = %v, %v", acked, err)
	}
}

func TestDeviceLimitAndHandover(t *testing.T) {
	w := newWorld(t)
	first, second := w.user(t, "254711111111"), w.user(t, "254722222222")
	w.register(t, first, "shared-device-token")
	w.register(t, second, "shared-device-token")
	w.notify(t, events.TypeRideStatus, first)
	if err := w.service.DeliverPending(t.Context()); err != nil {
		t.Fatalf("DeliverPending: %v", err)
	}
	if got := w.pushStatus(t); got != "no_device" {
		t.Errorf("the previous owner of a device still gets its pushes: %s", got)
	}
	for i := range 7 {
		w.now = w.now.Add(time.Second)
		w.register(t, second, "device-token-"+string(rune('a'+i)))
	}
	var active int
	if err := w.pool.QueryRow(t.Context(), `SELECT count(*) FROM push_tokens WHERE user_id = $1 AND revoked_at IS NULL`, second).Scan(&active); err != nil || active != 5 {
		t.Errorf("active devices = %d, %v, want 5", active, err)
	}
}
