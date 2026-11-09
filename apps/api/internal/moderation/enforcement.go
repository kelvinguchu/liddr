package moderation

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	actionWarning     = "warning"
	actionRestriction = "feature_restriction"
	actionSuspension  = "temporary_suspension"
	actionBan         = "permanent_ban"

	enforcementActive = "active"
	enforcementLifted = "lifted"
	enforcementEnded  = "expired"

	// Enforcement scopes.
	ScopePlatform      = "platform"
	ScopeCommunication = "communication"

	maxSuspension = 365 * 24 * time.Hour
	sweepInterval = time.Minute
	sweepBatch    = 200
)

// Penalty is an enforcement to apply to an account.
type Penalty struct {
	UserID     uuid.UUID
	ReportID   *uuid.UUID
	Actor      uuid.UUID
	Action     string
	ReasonCode string
	ReasonText *string
	EndsAt     *time.Time
	// Scope is platform when empty. A communication penalty only stops messages.
	Scope string
}

// Enforcement is a recorded penalty.
type Enforcement struct {
	ID         uuid.UUID
	UserID     uuid.UUID
	ReportID   *uuid.UUID
	Action     string
	Status     string
	ReasonCode string
	StartsAt   time.Time
	EndsAt     *time.Time
	LiftedAt   *time.Time
}

// Apply records a penalty that did not come from a report.
func (s *Service) Apply(ctx context.Context, p Penalty) (Enforcement, error) {
	var out Enforcement
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		var err error
		out, err = s.applyInTx(ctx, q, p)
		return err
	})
	return out, err
}

// ApplyInTx records a penalty inside the caller's transaction. A nil Actor
// means the system decided.
func (s *Service) ApplyInTx(ctx context.Context, q *store.Queries, p Penalty) (Enforcement, error) {
	return s.applyInTx(ctx, q, p)
}

func (s *Service) applyInTx(ctx context.Context, q *store.Queries, p Penalty) (Enforcement, error) {
	if p.UserID == p.Actor {
		return Enforcement{}, ErrConflictOfInterest
	}
	var actor *uuid.UUID
	if p.Actor != uuid.Nil {
		actor = new(p.Actor)
	}
	if !slices.Contains([]string{actionWarning, actionRestriction, actionSuspension, actionBan}, p.Action) {
		return Enforcement{}, ErrInvalidDecision
	}
	now := s.now()
	var ends *time.Time
	if p.Action == actionSuspension {
		if p.EndsAt == nil || !p.EndsAt.After(now) || p.EndsAt.Sub(now) > maxSuspension {
			return Enforcement{}, ErrInvalidEnd
		}
		ends = p.EndsAt
	}
	if p.Scope == "" {
		p.Scope = ScopePlatform
	}
	if p.Scope != ScopePlatform && p.Scope != ScopeCommunication {
		return Enforcement{}, ErrInvalidDecision
	}
	if err := lockUser(ctx, q, p.UserID); err != nil {
		return Enforcement{}, err
	}
	row, err := q.InsertEnforcement(ctx, store.InsertEnforcementParams{
		ID: uuid.New(), UserID: p.UserID, ReportID: p.ReportID, ActorID: actor, Action: p.Action, Scope: p.Scope,
		ReasonCode: p.ReasonCode, ReasonText: p.ReasonText, Now: now, EndsAt: ends,
	})
	if err != nil {
		return Enforcement{}, fmt.Errorf("insert enforcement: %w", err)
	}
	if err := s.syncAccount(ctx, q, p.UserID, now); err != nil {
		return Enforcement{}, err
	}
	return Enforcement{
		ID: row.ID, UserID: row.UserID, ReportID: row.ReportID, Action: row.Action, Status: row.Status,
		ReasonCode: row.ReasonCode, StartsAt: row.StartsAt, EndsAt: row.EndsAt, LiftedAt: row.LiftedAt,
	}, nil
}

func lockUser(ctx context.Context, q *store.Queries, userID uuid.UUID) error {
	if err := q.LockKey(ctx, "moderation:user:"+userID.String()); err != nil {
		return fmt.Errorf("lock user: %w", err)
	}
	return nil
}

// effectiveStatus is the most severe state any active penalty requires. It is
// always derived from every active penalty, so one penalty ending, or a mere
// warning arriving, can never undo a heavier one.
func effectiveStatus(actions []string) string {
	switch {
	case slices.Contains(actions, actionBan):
		return "banned"
	case slices.Contains(actions, actionSuspension):
		return "suspended"
	case slices.Contains(actions, actionRestriction):
		return "restricted"
	default:
		return "active"
	}
}

func (s *Service) syncAccount(ctx context.Context, q *store.Queries, userID uuid.UUID, now time.Time) error {
	actions, err := q.ListActiveEnforcementActions(ctx, userID)
	if err != nil {
		return fmt.Errorf("list penalties: %w", err)
	}
	current, err := q.GetAccountStatus(ctx, userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("load account: %w", err)
	}
	// Deactivation is the account holder's own choice, and no penalty ending
	// should bring the account back.
	status := effectiveStatus(actions)
	if current == "deactivated" || current == status {
		return nil
	}
	if err := q.SetAccountStatus(ctx, store.SetAccountStatusParams{Status: status, Now: now, ID: userID}); err != nil {
		return fmt.Errorf("update account: %w", err)
	}
	if status == "banned" || status == "suspended" {
		if err := q.TakeDriverOffline(ctx, store.TakeDriverOfflineParams{Now: now, UserID: userID}); err != nil {
			return fmt.Errorf("take driver offline: %w", err)
		}
	}
	return nil
}

// Lift ends a penalty early.
func (s *Service) Lift(ctx context.Context, id, actor uuid.UUID) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetEnforcementForUpdate(ctx, id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load enforcement: %w", err)
		}
		if row.UserID == actor {
			return ErrConflictOfInterest
		}
		if row.Status != enforcementActive {
			return ErrEnforcementClosed
		}
		if err := lockUser(ctx, q, row.UserID); err != nil {
			return err
		}
		if err := q.FinishEnforcement(ctx, store.FinishEnforcementParams{Status: enforcementLifted, Now: new(now), LiftedBy: new(actor), ID: id}); err != nil {
			return fmt.Errorf("lift enforcement: %w", err)
		}
		return s.syncAccount(ctx, q, row.UserID, now)
	})
}

// ListEnforcements returns penalties in one status, newest first.
func (s *Service) ListEnforcements(ctx context.Context, status string, limit, offset int32) ([]Enforcement, error) {
	rows, err := s.queries.ListEnforcements(ctx, store.ListEnforcementsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list enforcements: %w", err)
	}
	out := make([]Enforcement, len(rows))
	for i, r := range rows {
		out[i] = Enforcement{ID: r.ID, UserID: r.UserID, ReportID: r.ReportID, Action: r.Action, Status: r.Status, ReasonCode: r.ReasonCode, StartsAt: r.StartsAt, EndsAt: r.EndsAt, LiftedAt: r.LiftedAt}
	}
	return out, nil
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
