package realtime

import (
	"context"
	"log/slog"
	"strings"
	"testing"

	"github.com/google/uuid"
	"go.uber.org/goleak"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
)

func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}

func frameOf(size int) []byte { return []byte(strings.Repeat("x", size)) }

func TestQueueEvictsOldestLocationToFit(t *testing.T) {
	c := newClient(uuid.New(), func() {})
	chunk := maxQueuedBytes / 4

	for range 4 {
		if _, ok := c.enqueue(frameOf(chunk), true); !ok {
			t.Fatal("location frame refused")
		}
	}
	first := []byte("marker")
	c.mu.Lock()
	c.queue[0].data = frameOf(chunk)[:chunk-len(first)]
	c.queue[0].data = append(c.queue[0].data, first...)
	c.mu.Unlock()

	dropped, ok := c.enqueue(frameOf(chunk), false)
	if !ok || dropped != 1 {
		t.Fatalf("enqueue = %d, %v, want 1 dropped and accepted", dropped, ok)
	}
	for _, frame := range c.drain() {
		if strings.HasSuffix(string(frame), "marker") {
			t.Error("the oldest location frame was not the one dropped")
		}
	}
}

func TestQueueRefusesImportantFrameWhenOnlyImportantFramesRemain(t *testing.T) {
	c := newClient(uuid.New(), func() {})
	for range 4 {
		if _, ok := c.enqueue(frameOf(maxQueuedBytes/4), false); !ok {
			t.Fatal("frame refused early")
		}
	}
	if _, ok := c.enqueue(frameOf(10), false); ok {
		t.Error("an important frame was accepted beyond the byte limit")
	}
}

func TestHubDisconnectsClientThatMissesAnImportantFrame(t *testing.T) {
	hub := NewHub(slog.New(slog.DiscardHandler))
	kicked := false
	c := newClient(uuid.New(), func() { kicked = true })
	hub.add(c)
	for range 4 {
		c.enqueue(frameOf(maxQueuedBytes/4), false)
	}
	hub.enqueue(c, frameOf(10), false)
	if !kicked {
		t.Error("client was not disconnected")
	}
}

func TestHubRoutesOnlyToRecipients(t *testing.T) {
	hub := NewHub(slog.New(slog.DiscardHandler))
	alice, bob := newClient(uuid.New(), func() {}), newClient(uuid.New(), func() {})
	hub.add(alice)
	hub.add(bob)

	ride := uuid.New()
	payload := `{"to":["` + alice.userID.String() + `"],"event":{"type":"` + events.TypeRideStatus + `","ride_id":"` + ride.String() + `","status":"accepted"}}`
	hub.deliver(context.WithoutCancel(t.Context()), payload)

	if got := len(alice.drain()); got != 1 {
		t.Errorf("alice got %d frames, want 1", got)
	}
	if got := len(bob.drain()); got != 0 {
		t.Errorf("bob got %d frames, want 0", got)
	}
}

func TestConnectionLimitPerUser(t *testing.T) {
	hub := NewHub(slog.New(slog.DiscardHandler))
	user := uuid.New()
	var clients []*client
	for range maxConnsPerUser {
		c := newClient(user, func() {})
		if !hub.add(c) {
			t.Fatal("connection refused below the limit")
		}
		clients = append(clients, c)
	}
	if hub.add(newClient(user, func() {})) {
		t.Error("connection accepted beyond the limit")
	}
	hub.remove(clients[0])
	if !hub.add(newClient(user, func() {})) {
		t.Error("connection refused after one closed")
	}
}

func TestUnreadableEventIsIgnored(t *testing.T) {
	hub := NewHub(slog.New(slog.DiscardHandler))
	hub.deliver(context.WithoutCancel(t.Context()), "not json")
}
