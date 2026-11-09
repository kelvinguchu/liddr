// Package notifications keeps the in-app inbox and delivers it by push.
package notifications

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/push"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	defaultListLimit = 30
	maxListLimit     = 100
	maxDevices       = 5
	maxTokenLength   = 4096
	minTokenLength   = 8

	pollInterval = time.Second
	batchSize    = 50
	claimLease   = time.Minute
	maxAttempts  = 5
	sendTimeout  = 30 * time.Second

	offerPushWindow = 20 * time.Second
	pushWindow      = time.Hour
)

// Errors returned to callers.
var (
	ErrNotFound     = errors.New("notification not found")
	ErrInvalidToken = errors.New("push token is not valid")
)

// Config holds the dependencies of a Service. Push is nil when no Firebase
// project is configured; the inbox still works, and nothing is marked as sent.
type Config struct {
	Pool   *pgxpool.Pool
	Push   *push.Client
	Now    func() time.Time
	Logger *slog.Logger
}

// Service implements the inbox and push delivery.
type Service struct {
	queries *store.Queries
	pool    *pgxpool.Pool
	push    *push.Client
	now     func() time.Time
	logger  *slog.Logger
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{queries: store.New(cfg.Pool), pool: cfg.Pool, push: cfg.Push, now: cfg.Now, logger: cfg.Logger}
}

// Notification is one inbox entry.
type Notification struct {
	ID        uuid.UUID
	EventType string
	RideID    *uuid.UUID
	OfferID   *uuid.UUID
	Status    *string
	AckedAt   *time.Time
	CreatedAt time.Time
}

// List returns a user's newest notifications.
func (s *Service) List(ctx context.Context, userID uuid.UUID, includeAcked bool, limit int32) ([]Notification, error) {
	if limit <= 0 || limit > maxListLimit {
		limit = defaultListLimit
	}
	rows, err := s.queries.ListNotifications(ctx, store.ListNotificationsParams{UserID: userID, IncludeAcked: includeAcked, RowLimit: limit})
	if err != nil {
		return nil, fmt.Errorf("list notifications: %w", err)
	}
	out := make([]Notification, len(rows))
	for i, row := range rows {
		out[i] = Notification{ID: row.ID, EventType: row.EventType, RideID: row.RideID, OfferID: row.OfferID, Status: row.Status, AckedAt: row.AckedAt, CreatedAt: row.CreatedAt}
	}
	return out, nil
}

// Delivery is one notification as staff see it when diagnosing a ride.
type Delivery struct {
	ID         uuid.UUID
	UserID     uuid.UUID
	EventType  string
	Status     *string
	PushStatus string
	Attempts   int32
	AckedAt    *time.Time
	CreatedAt  time.Time
}

// ForRide lists what was sent about a ride.
func (s *Service) ForRide(ctx context.Context, rideID uuid.UUID) ([]Delivery, error) {
	rows, err := s.queries.ListRideNotifications(ctx, new(rideID))
	if err != nil {
		return nil, fmt.Errorf("list deliveries: %w", err)
	}
	out := make([]Delivery, len(rows))
	for i, r := range rows {
		out[i] = Delivery{ID: r.ID, UserID: r.UserID, EventType: r.EventType, Status: r.Status, PushStatus: r.PushStatus, Attempts: r.PushAttempts, AckedAt: r.AckedAt, CreatedAt: r.CreatedAt}
	}
	return out, nil
}

// UnreadCount returns how many notifications are unacknowledged.
func (s *Service) UnreadCount(ctx context.Context, userID uuid.UUID) (int64, error) {
	count, err := s.queries.CountUnackedNotifications(ctx, userID)
	if err != nil {
		return 0, fmt.Errorf("count notifications: %w", err)
	}
	return count, nil
}

// Ack marks a notification read. It is safe to repeat.
func (s *Service) Ack(ctx context.Context, userID, id uuid.UUID) error {
	rows, err := s.queries.AckNotification(ctx, store.AckNotificationParams{Now: new(s.now()), ID: id, UserID: userID})
	if err != nil {
		return fmt.Errorf("ack notification: %w", err)
	}
	if rows == 0 {
		return ErrNotFound
	}
	return nil
}

// Device identifies the sign-in registering a push token.
type Device struct {
	UserID   uuid.UUID
	FamilyID uuid.UUID
	Token    string
	Platform string
}

// RegisterDevice stores a token and keeps only the account's newest few.
func (s *Service) RegisterDevice(ctx context.Context, d Device) error {
	token := strings.TrimSpace(d.Token)
	if len(token) < minTokenLength || len(token) > maxTokenLength {
		return ErrInvalidToken
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "push:"+d.UserID.String()); err != nil {
			return fmt.Errorf("lock devices: %w", err)
		}
		err := q.UpsertPushToken(ctx, store.UpsertPushTokenParams{UserID: d.UserID, FamilyID: d.FamilyID, Token: token, Platform: d.Platform, Now: now})
		if err != nil {
			return fmt.Errorf("store token: %w", err)
		}
		if err := q.TrimPushTokens(ctx, store.TrimPushTokensParams{Now: new(now), UserID: d.UserID, Keep: maxDevices}); err != nil {
			return fmt.Errorf("trim tokens: %w", err)
		}
		return nil
	})
}

// RevokeDevice stops pushes to one of the user's tokens. Revoking an unknown
// token succeeds, because the caller's goal has been met either way.
func (s *Service) RevokeDevice(ctx context.Context, userID uuid.UUID, token string) error {
	err := s.queries.RevokeUserPushToken(ctx, store.RevokeUserPushTokenParams{Now: new(s.now()), UserID: userID, Token: strings.TrimSpace(token)})
	if err != nil {
		return fmt.Errorf("revoke token: %w", err)
	}
	return nil
}
