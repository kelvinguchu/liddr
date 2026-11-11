// Package retention deletes personal data once it no longer has a purpose.
package retention

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	batchSize   = 1000
	maxBatches  = 200
	runInterval = time.Hour

	week = 7 * 24 * time.Hour
	day  = 24 * time.Hour
)

// Sweeper removes rows that have passed their retention period.
type Sweeper struct {
	queries *store.Queries
	now     func() time.Time
	logger  *slog.Logger
}

// NewSweeper returns a Sweeper.
func NewSweeper(queries *store.Queries, now func() time.Time, logger *slog.Logger) *Sweeper {
	return &Sweeper{queries: queries, now: now, logger: logger}
}

type rule struct {
	name  string
	after time.Duration
	run   func(ctx context.Context, before time.Time) (int64, error)
}

// rules restate the periods given beside each table in the migrations. Deletes
// run in small batches so that a backlog never holds long locks.
func (s *Sweeper) rules() []rule {
	q := s.queries
	return []rule{
		{"auth_challenges", week, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteExpiredAuthChallenges(ctx, store.DeleteExpiredAuthChallengesParams{Before: before, Batch: batchSize})
		}},
		{"email_challenges", week, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteExpiredEmailChallenges(ctx, store.DeleteExpiredEmailChallengesParams{Before: before, Batch: batchSize})
		}},
		{"auth_sessions", 30 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteExpiredSessions(ctx, store.DeleteExpiredSessionsParams{Before: before, Batch: batchSize})
		}},
		{"audit_events", 365 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteOldAuditEvents(ctx, store.DeleteOldAuditEventsParams{Before: before, Batch: batchSize})
		}},
		{"notifications", 30 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteOldNotifications(ctx, store.DeleteOldNotificationsParams{Before: before, Batch: batchSize})
		}},
		{"ride_quotes", 30 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteUnusedQuotes(ctx, store.DeleteUnusedQuotesParams{Before: before, Batch: batchSize})
		}},
		{"ride_messages", 90 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteOldRideMessages(ctx, store.DeleteOldRideMessagesParams{Before: new(before), Batch: batchSize})
		}},
		{"verification_uploads", week, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteUnusedVerificationUploads(ctx, store.DeleteUnusedVerificationUploadsParams{Before: before, Batch: batchSize})
		}},
		{"send_proof_uploads", week, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteUnusedProofUploads(ctx, store.DeleteUnusedProofUploadsParams{Before: before, Batch: batchSize})
		}},
		{"mpesa_unmatched_callbacks", 180 * day, func(ctx context.Context, before time.Time) (int64, error) {
			return q.DeleteOldUnmatchedCallbacks(ctx, store.DeleteOldUnmatchedCallbacksParams{Before: before, Batch: batchSize})
		}},
	}
}

// Sweep applies every rule once.
func (s *Sweeper) Sweep(ctx context.Context) error {
	now := s.now()
	var errs []error
	for _, r := range s.rules() {
		var total int64
		for range maxBatches {
			deleted, err := r.run(ctx, now.Add(-r.after))
			if err != nil {
				errs = append(errs, fmt.Errorf("sweep %s: %w", r.name, err))
				break
			}
			total += deleted
			if deleted < batchSize {
				break
			}
		}
		if total > 0 {
			s.logger.LogAttrs(ctx, slog.LevelInfo, "retention sweep deleted rows", slog.String("table", r.name), slog.Int64("rows", total))
		}
	}
	return errors.Join(errs...)
}

// Run sweeps hourly until ctx ends.
func (s *Sweeper) Run(ctx context.Context) {
	ticker := time.NewTicker(runInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.Sweep(ctx); err != nil && ctx.Err() == nil {
				s.logger.LogAttrs(ctx, slog.LevelError, "retention sweep failed", slog.Any("error", err))
			}
		}
	}
}
