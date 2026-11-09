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

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
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

// Run delivers pending pushes until ctx ends.
func (s *Service) Run(ctx context.Context) {
	if s.push == nil {
		s.logger.LogAttrs(ctx, slog.LevelWarn, "push is not configured; notifications stay in the app inbox")
		return
	}
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.DeliverPending(ctx); err != nil && ctx.Err() == nil {
				s.logger.LogAttrs(ctx, slog.LevelError, "push cycle failed", slog.Any("error", err))
			}
		}
	}
}

// DeliverPending sends one batch. The claim is its own statement, so nothing
// holds a transaction while Firebase answers.
func (s *Service) DeliverPending(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	now := s.now()
	claimed, err := s.queries.ClaimNotificationsToPush(ctx, store.ClaimNotificationsToPushParams{LeaseUntil: new(now.Add(claimLease)), Now: new(now), Batch: batchSize})
	if err != nil {
		return fmt.Errorf("claim notifications: %w", err)
	}
	var errs []error
	for _, row := range claimed {
		errs = append(errs, s.deliver(ctx, row, now))
	}
	return errors.Join(errs...)
}

func (s *Service) deliver(ctx context.Context, row store.ClaimNotificationsToPushRow, now time.Time) error {
	window, ttl := pushWindow, pushWindow
	if row.EventType == events.TypeOfferCreated {
		// An offer lasts seconds. Waking a phone for one already over only annoys.
		window, ttl = offerPushWindow, offerPushWindow
	}
	if now.Sub(row.CreatedAt) > window {
		return s.finish(ctx, row.ID, "expired")
	}
	tokens, err := s.queries.ListActivePushTokens(ctx, row.UserID)
	if err != nil {
		return fmt.Errorf("list tokens: %w", err)
	}
	sent, retry := false, false
	message := push.Message{Data: payload(row), TTL: ttl}
	for _, token := range tokens {
		message.Token = token.Token
		switch err := s.push.Send(ctx, message); {
		case err == nil:
			sent = true
		case errors.Is(err, push.ErrUnregistered):
			if err := s.queries.RevokePushToken(ctx, store.RevokePushTokenParams{Now: new(now), ID: token.ID}); err != nil {
				return fmt.Errorf("revoke dead token: %w", err)
			}
		default:
			retry = true
			s.logger.LogAttrs(ctx, slog.LevelWarn, "push send failed", slog.Any("error", err))
		}
	}
	switch {
	case sent:
		return s.finish(ctx, row.ID, "sent")
	case retry && row.PushAttempts < maxAttempts:
		return nil // The lease lapses and a later cycle tries again.
	case retry:
		return s.finish(ctx, row.ID, "failed")
	default:
		return s.finish(ctx, row.ID, "no_device")
	}
}

func (s *Service) finish(ctx context.Context, id uuid.UUID, status string) error {
	if err := s.queries.SetNotificationPushStatus(ctx, store.SetNotificationPushStatusParams{PushStatus: status, ID: id}); err != nil {
		return fmt.Errorf("record push result: %w", err)
	}
	return nil
}

// payload carries identifiers only. The app fetches details over its session.
func payload(row store.ClaimNotificationsToPushRow) map[string]string {
	data := map[string]string{"notification_id": row.ID.String(), "event_type": row.EventType}
	if row.RideID != nil {
		data["ride_id"] = row.RideID.String()
	}
	if row.OfferID != nil {
		data["offer_id"] = row.OfferID.String()
	}
	if row.Status != nil {
		data["status"] = *row.Status
	}
	return data
}
