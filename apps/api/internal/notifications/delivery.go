package notifications

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/push"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

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
