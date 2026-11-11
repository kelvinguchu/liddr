// Package messages is the in-ride chat between a rider and their driver.
package messages

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	defaultLimit    = 100
	maxLimit        = 300
	maxBody         = 1000
	perMinute       = 30
	reportWindow    = 7 * 24 * time.Hour
	autoRestrictAt  = 3
	signalCooldown  = 2 * 24 * time.Hour
	defaultCategory = "harassment_or_abuse"

	typeText        = "text"
	typeQuickAction = "quick_action"
)

// Errors returned to callers.
var (
	ErrNotFound      = errors.New("not found")
	ErrNoDriver      = errors.New("ride has no driver yet")
	ErrClosed        = errors.New("chat for this ride is closed")
	ErrInvalidBody   = errors.New("message is not valid")
	ErrInvalidAction = errors.New("quick action is not valid")
	ErrRestricted    = errors.New("account cannot send messages")
	ErrRateLimited   = errors.New("too many messages")
	ErrNotRecipient  = errors.New("message was not sent to this account")
	ErrOwnMessage    = errors.New("cannot report your own message")
)

// QuickAction is a canned message.
type QuickAction struct {
	Code, English, Swahili string
}

var quickActions = []QuickAction{
	{"arrived", "I have arrived", "Nimefika"},
	{"on_my_way", "I am on my way", "Niko njiani"},
	{"running_late", "I am running late", "Nachelewa"},
	{"cant_find_you", "I cannot find you", "Siwezi kukupata"},
	{"call_me", "Please call me", "Tafadhali nipigie simu"},
}

// QuickActions lists the canned messages.
func QuickActions() []QuickAction {
	return append([]QuickAction(nil), quickActions...)
}

// Config holds the dependencies of a Service.
type Config struct {
	Pool       *pgxpool.Pool
	Moderation *moderation.Service
	Now        func() time.Time
}

// Service implements chat.
type Service struct {
	pool       *pgxpool.Pool
	queries    *store.Queries
	moderation *moderation.Service
	now        func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{pool: cfg.Pool, queries: store.New(cfg.Pool), moderation: cfg.Moderation, now: cfg.Now}
}

// Message is one chat message.
type Message struct {
	Seq             int64
	ID              uuid.UUID
	SenderID        uuid.UUID
	SenderRole      string
	Type            string
	QuickActionCode *string
	Body            string
	ReadAt          *time.Time
	CreatedAt       time.Time
}

type party struct {
	ride      store.GetRideForMessagingRow
	other     uuid.UUID
	role      string
	hasDriver bool
}

// findParty confirms the user is on the ride. A stranger is told it does not
// exist, so ride IDs cannot be probed through chat.
func findParty(ctx context.Context, q *store.Queries, rideID, userID uuid.UUID) (party, error) {
	ride, err := q.GetRideForMessaging(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return party{}, ErrNotFound
	}
	if err != nil {
		return party{}, fmt.Errorf("load ride: %w", err)
	}
	switch {
	case ride.RiderID == userID && ride.DriverID != nil:
		return party{ride: ride, other: *ride.DriverID, role: "rider", hasDriver: true}, nil
	case ride.RiderID == userID:
		return party{ride: ride, role: "rider"}, nil
	case ride.DriverID != nil && *ride.DriverID == userID:
		return party{ride: ride, other: ride.RiderID, role: "driver", hasDriver: true}, nil
	default:
		return party{}, ErrNotFound
	}
}

// Thread is a page of a ride's chat.
type Thread struct {
	Messages []Message
	NextSeq  int64
	Unread   int64
}

// List returns messages after a position, oldest first.
func (s *Service) List(ctx context.Context, rideID, userID uuid.UUID, afterSeq int64, limit int32) (Thread, error) {
	if _, err := findParty(ctx, s.queries, rideID, userID); err != nil {
		return Thread{}, err
	}
	if limit <= 0 || limit > maxLimit {
		limit = defaultLimit
	}
	rows, err := s.queries.ListRideMessages(ctx, store.ListRideMessagesParams{RideID: rideID, AfterSeq: afterSeq, UserID: userID, RowLimit: limit})
	if err != nil {
		return Thread{}, fmt.Errorf("list messages: %w", err)
	}
	unread, err := s.queries.CountUnreadRideMessages(ctx, store.CountUnreadRideMessagesParams{RideID: rideID, UserID: userID})
	if err != nil {
		return Thread{}, fmt.Errorf("count unread: %w", err)
	}
	out := Thread{Messages: make([]Message, len(rows)), NextSeq: afterSeq, Unread: unread}
	for i, r := range rows {
		out.Messages[i] = Message{Seq: r.Seq, ID: r.ID, SenderID: r.SenderID, SenderRole: r.SenderRole, Type: r.MessageType, QuickActionCode: r.QuickActionCode, Body: r.Body, ReadAt: r.ReadAt, CreatedAt: r.CreatedAt}
		out.NextSeq = r.Seq
	}
	return out, nil
}

// Draft is a message to send: either Body, or QuickAction.
type Draft struct {
	RideID      uuid.UUID
	SenderID    uuid.UUID
	Body        string
	QuickAction *string
}

func compose(d Draft) (kind, body string, code *string, err error) {
	if d.QuickAction != nil {
		for _, action := range quickActions {
			if action.Code == *d.QuickAction {
				return typeQuickAction, action.English, d.QuickAction, nil
			}
		}
		return "", "", nil, ErrInvalidAction
	}
	body = strings.TrimSpace(d.Body)
	if body == "" || len(body) > maxBody {
		return "", "", nil, ErrInvalidBody
	}
	return typeText, body, nil, nil
}

// Send delivers a message to the other person on the ride.
func (s *Service) Send(ctx context.Context, d Draft) (Message, error) {
	kind, body, code, err := compose(d)
	if err != nil {
		return Message{}, err
	}
	now := s.now()
	var out Message
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "messages:"+d.SenderID.String()); err != nil {
			return fmt.Errorf("lock sender: %w", err)
		}
		p, err := findParty(ctx, q, d.RideID, d.SenderID)
		if err != nil {
			return err
		}
		if !p.hasDriver {
			return ErrNoDriver
		}
		if p.ride.Status == "completed" || p.ride.Status == "cancelled" {
			return ErrClosed
		}
		restricted, err := q.HasCommunicationRestriction(ctx, store.HasCommunicationRestrictionParams{UserID: d.SenderID, Now: new(now)})
		if err != nil {
			return fmt.Errorf("check restriction: %w", err)
		}
		if restricted {
			return ErrRestricted
		}
		recent, err := q.CountMessagesSince(ctx, store.CountMessagesSinceParams{SenderID: d.SenderID, Since: now.Add(-time.Minute)})
		if err != nil {
			return fmt.Errorf("count messages: %w", err)
		}
		if recent >= perMinute {
			return ErrRateLimited
		}
		row, err := q.InsertRideMessage(ctx, store.InsertRideMessageParams{
			ID: uuid.New(), RideID: d.RideID, SenderID: d.SenderID, RecipientID: p.other, SenderRole: p.role,
			MessageType: kind, QuickActionCode: code, Body: body, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert message: %w", err)
		}
		out = Message{Seq: row.Seq, ID: row.ID, SenderID: row.SenderID, SenderRole: row.SenderRole, Type: row.MessageType, QuickActionCode: row.QuickActionCode, Body: row.Body, CreatedAt: row.CreatedAt}
		return events.Notify(ctx, q, events.Event{Type: events.TypeRideMessage, RideID: new(d.RideID)}, p.other)
	})
	if err != nil {
		return Message{}, err
	}
	return out, nil
}
