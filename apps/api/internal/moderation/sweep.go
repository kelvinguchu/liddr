package moderation

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// EnforcementMetric is how many penalties are in one state.
type EnforcementMetric struct {
	Action, Status string
	Total          int64
}

// Metrics summarizes penalties, and how many suspensions are overdue to end.
func (s *Service) Metrics(ctx context.Context) ([]EnforcementMetric, int64, error) {
	rows, err := s.queries.EnforcementCounts(ctx)
	if err != nil {
		return nil, 0, fmt.Errorf("count enforcements: %w", err)
	}
	overdue, err := s.queries.CountOverdueSuspensions(ctx, new(s.now()))
	if err != nil {
		return nil, 0, fmt.Errorf("count overdue: %w", err)
	}
	out := make([]EnforcementMetric, len(rows))
	for i, r := range rows {
		out[i] = EnforcementMetric{Action: r.Action, Status: r.Status, Total: r.Total}
	}
	return out, overdue, nil
}

// ExpireDue ends suspensions whose time has come.
func (s *Service) ExpireDue(ctx context.Context) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		due, err := q.ClaimDueEnforcements(ctx, store.ClaimDueEnforcementsParams{Now: new(now), Batch: sweepBatch})
		if err != nil {
			return fmt.Errorf("claim enforcements: %w", err)
		}
		for _, row := range due {
			if err := lockUser(ctx, q, row.UserID); err != nil {
				return err
			}
			if err := q.FinishEnforcement(ctx, store.FinishEnforcementParams{Status: enforcementEnded, Now: new(now), ID: row.ID}); err != nil {
				return fmt.Errorf("expire enforcement: %w", err)
			}
			if err := s.syncAccount(ctx, q, row.UserID, now); err != nil {
				return err
			}
		}
		return nil
	})
}

// Run expires suspensions until ctx ends.
func (s *Service) Run(ctx context.Context, logger *slog.Logger) {
	ticker := time.NewTicker(sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.ExpireDue(ctx); err != nil && ctx.Err() == nil {
				logger.LogAttrs(ctx, slog.LevelError, "enforcement sweep failed", slog.Any("error", err))
			}
		}
	}
}
