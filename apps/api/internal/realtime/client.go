package realtime

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

const (
	maxQueuedBytes  = 64 << 10
	writeTimeout    = 10 * time.Second
	pingInterval    = 25 * time.Second
	pongTimeout     = 10 * time.Second
	sessionRecheck  = time.Minute
	maxInboundBytes = 512
)

// client is one connection. Its queue is bounded in bytes, and publishers add
// to it without waiting, so a slow client cannot hold up anyone else.
type client struct {
	userID uuid.UUID
	cancel context.CancelFunc

	mu     sync.Mutex
	queue  []queuedFrame
	queued int

	wake chan struct{}
}

type queuedFrame struct {
	data      []byte
	droppable bool
}

func newClient(userID uuid.UUID, cancel context.CancelFunc) *client {
	return &client{userID: userID, cancel: cancel, wake: make(chan struct{}, 1)}
}

func (c *client) kick() { c.cancel() }

// enqueue adds a frame. When full it evicts the oldest location frames to make
// room. It reports how many were evicted, and false if the frame did not fit.
func (c *client) enqueue(data []byte, droppable bool) (dropped int, ok bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for c.queued+len(data) > maxQueuedBytes {
		index := -1
		for i, frame := range c.queue {
			if frame.droppable {
				index = i
				break
			}
		}
		if index < 0 {
			return dropped, droppable
		}
		c.queued -= len(c.queue[index].data)
		c.queue = append(c.queue[:index], c.queue[index+1:]...)
		dropped++
	}
	c.queue = append(c.queue, queuedFrame{data: data, droppable: droppable})
	c.queued += len(data)
	select {
	case c.wake <- struct{}{}:
	default:
	}
	return dropped, true
}

func (c *client) drain() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	frames := make([][]byte, len(c.queue))
	for i, frame := range c.queue {
		frames[i] = frame.data
	}
	c.queue = nil
	c.queued = 0
	return frames
}

// Options configure Serve.
type Options struct {
	UserID         uuid.UUID
	OriginPatterns []string
	// StillValid reports whether the connection's session remains good.
	StillValid func(ctx context.Context) bool
	// ShutdownJitter spreads disconnects so that clients do not all reconnect at once.
	ShutdownJitter time.Duration
}

// Serve upgrades the request and runs the connection until it ends. The
// connection's life is bounded by base, not by the HTTP request.
func (h *Hub) Serve(base context.Context, w http.ResponseWriter, r *http.Request, opts Options) {
	h.sockets.Add(1)
	defer h.sockets.Done()

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: opts.OriginPatterns})
	if err != nil {
		h.logger.LogAttrs(r.Context(), slog.LevelInfo, "websocket upgrade refused", slog.Any("error", err))
		return
	}
	conn.SetReadLimit(maxInboundBytes)

	ctx, cancel := context.WithCancel(context.WithoutCancel(r.Context()))
	defer cancel()
	stopWatch := context.AfterFunc(base, func() {
		// Spread reconnects across the window, then end this connection.
		time.AfterFunc(jitter(opts.ShutdownJitter), cancel)
	})
	defer stopWatch()

	c := newClient(opts.UserID, cancel)
	if !h.add(c) {
		_ = conn.Close(websocket.StatusPolicyViolation, "too many connections") // Already leaving.
		return
	}
	defer h.remove(c)

	// CloseRead keeps a reader running, which processes pings and notices a
	// client that has gone. It rejects any data message, since none are expected.
	ctx = conn.CloseRead(ctx)
	h.writeLoop(ctx, conn, c, opts)
}

func jitter(window time.Duration) time.Duration {
	if window <= 0 {
		return 0
	}
	return rand.N(window) //nolint:gosec // Spreading reconnects needs no secrecy.
}

func (h *Hub) writeLoop(ctx context.Context, conn *websocket.Conn, c *client, opts Options) {
	ping := time.NewTicker(pingInterval)
	defer ping.Stop()
	recheck := time.NewTicker(sessionRecheck)
	defer recheck.Stop()

	status, reason := websocket.StatusGoingAway, "closing"
	defer func() {
		// The peer may already be gone. There is nothing further to do.
		_ = conn.Close(status, reason)
	}()

	for {
		select {
		case <-ctx.Done():
			return
		case <-c.wake:
			for _, frame := range c.drain() {
				if err := write(ctx, conn, frame); err != nil {
					return
				}
			}
		case <-ping.C:
			pingCtx, cancel := context.WithTimeout(ctx, pongTimeout)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				return
			}
		case <-recheck.C:
			if !opts.StillValid(ctx) {
				status, reason = websocket.StatusPolicyViolation, "session ended"
				return
			}
		}
	}
}

func write(ctx context.Context, conn *websocket.Conn, frame []byte) error {
	writeCtx, cancel := context.WithTimeout(ctx, writeTimeout)
	defer cancel()
	if err := conn.Write(writeCtx, websocket.MessageText, frame); err != nil {
		return errors.Join(errors.New("write frame"), err)
	}
	return nil
}
