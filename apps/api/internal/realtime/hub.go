// Package realtime pushes live updates to connected clients over WebSockets.
package realtime

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
)

const (
	maxConnsPerUser = 3
	listenRetry     = 2 * time.Second
)

// Hub tracks connected clients and routes events to them.
type Hub struct {
	logger *slog.Logger

	mu    sync.Mutex
	conns map[uuid.UUID]map[*client]struct{}

	droppedLocations atomic.Int64

	// sockets counts running connections so that shutdown can wait for them.
	sockets sync.WaitGroup
}

// NewHub returns an empty Hub.
func NewHub(logger *slog.Logger) *Hub {
	return &Hub{logger: logger, conns: map[uuid.UUID]map[*client]struct{}{}}
}

// Wait blocks until every connection has ended. Call it after new requests stop.
func (h *Hub) Wait() {
	h.sockets.Wait()
}

// DroppedLocations reports how many location frames slow clients have lost.
func (h *Hub) DroppedLocations() int64 {
	return h.droppedLocations.Load()
}

// add registers a client, returning false when the account is at its limit.
func (h *Hub) add(c *client) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.conns[c.userID]) >= maxConnsPerUser {
		return false
	}
	if h.conns[c.userID] == nil {
		h.conns[c.userID] = map[*client]struct{}{}
	}
	h.conns[c.userID][c] = struct{}{}
	return true
}

func (h *Hub) remove(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns[c.userID], c)
	if len(h.conns[c.userID]) == 0 {
		delete(h.conns, c.userID)
	}
}

func (h *Hub) clientsFor(users []uuid.UUID) []*client {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []*client
	for _, user := range users {
		for c := range h.conns[user] {
			out = append(out, c)
		}
	}
	return out
}

func (h *Hub) allClients() []*client {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []*client
	for _, set := range h.conns {
		for c := range set {
			out = append(out, c)
		}
	}
	return out
}

// deliver routes one notification. It never blocks on a client.
func (h *Hub) deliver(ctx context.Context, payload string) {
	var envelope events.Envelope
	if err := json.Unmarshal([]byte(payload), &envelope); err != nil {
		h.logger.LogAttrs(ctx, slog.LevelError, "unreadable realtime event", slog.Any("error", err))
		return
	}
	frame, err := json.Marshal(envelope.Event)
	if err != nil {
		h.logger.LogAttrs(ctx, slog.LevelError, "unencodable realtime event", slog.Any("error", err))
		return
	}
	droppable := envelope.Event.Type == events.TypeDriverLocation
	for _, c := range h.clientsFor(envelope.To) {
		h.enqueue(c, frame, droppable)
	}
}

func (h *Hub) enqueue(c *client, frame []byte, droppable bool) {
	dropped, ok := c.enqueue(frame, droppable)
	h.droppedLocations.Add(int64(dropped))
	if !ok {
		// An offer or status update could not be queued. Disconnecting makes
		// the client reconnect and resynchronize instead of silently missing it.
		c.kick()
	}
}

func (h *Hub) broadcastResync() {
	frame, err := json.Marshal(events.Event{Type: events.TypeResync})
	if err != nil {
		return
	}
	for _, c := range h.allClients() {
		h.enqueue(c, frame, false)
	}
}

// Listen forwards Postgres notifications until ctx ends. Each reconnect tells
// clients to resynchronize, because notifications sent in the gap are gone.
func (h *Hub) Listen(ctx context.Context, pool *pgxpool.Pool) {
	reconnected := false
	for ctx.Err() == nil {
		err := h.listenOnce(ctx, pool, &reconnected)
		if ctx.Err() != nil {
			return
		}
		h.logger.LogAttrs(ctx, slog.LevelWarn, "realtime listener lost", slog.Any("error", err))
		select {
		case <-ctx.Done():
			return
		case <-time.After(listenRetry):
		}
	}
}

func (h *Hub) listenOnce(ctx context.Context, pool *pgxpool.Pool, reconnected *bool) error {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err //nolint:wrapcheck // Only logged by Listen.
	}
	// The session has run LISTEN, so it must not return to the pool as is.
	defer func() { _ = conn.Hijack().Close(context.WithoutCancel(ctx)) }()

	if _, err := conn.Exec(ctx, "LISTEN "+events.Channel); err != nil {
		return err //nolint:wrapcheck // Only logged by Listen.
	}
	if *reconnected {
		h.broadcastResync()
	}
	*reconnected = true
	for {
		notification, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err //nolint:wrapcheck // Only logged by Listen.
		}
		h.deliver(ctx, notification.Payload)
	}
}
