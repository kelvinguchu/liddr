package ratings

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Rating is a rating as staff see it.
type Rating struct {
	ID              uuid.UUID
	RideID          uuid.UUID
	RatedBy         uuid.UUID
	RatedUser       uuid.UUID
	Score           int32
	Tags            []string
	Comment         *string
	IncludeInScore  bool
	ExclusionReason *string
	NullifiedAt     *time.Time
	SubmittedAt     time.Time
}

// List returns ratings newest first.
func (s *Service) List(ctx context.Context, ratedUser *uuid.UUID, excludedOnly bool, limit, offset int32) ([]Rating, error) {
	rows, err := s.queries.ListRatings(ctx, store.ListRatingsParams{RatedUser: ratedUser, ExcludedOnly: excludedOnly, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list ratings: %w", err)
	}
	out := make([]Rating, len(rows))
	for i, r := range rows {
		out[i] = Rating{
			ID: r.ID, RideID: r.RideID, RatedBy: r.RatedBy, RatedUser: r.RatedUser, Score: r.Score, Tags: r.ReasonTags,
			Comment: r.Comment, IncludeInScore: r.IncludeInScore, ExclusionReason: r.ExclusionReason,
			NullifiedAt: r.NullifiedAt, SubmittedAt: r.SubmittedAt,
		}
	}
	return out, nil
}

// Guardrail reports whether an account has enough recent ratings to act on.
type Guardrail struct {
	Recent, Minimum int64
	WindowDays      int32
}

// GuardrailFor reports on one account.
func (s *Service) GuardrailFor(ctx context.Context, user uuid.UUID) (Guardrail, error) {
	recent, err := s.queries.GetRatingGuardrail(ctx, store.GetRatingGuardrailParams{RatedUser: user, Since: s.now().Add(-guardrailWindow)})
	if err != nil {
		return Guardrail{}, fmt.Errorf("load guardrail: %w", err)
	}
	return Guardrail{Recent: recent, Minimum: guardrailMinimum, WindowDays: int32(guardrailWindow / (24 * time.Hour))}, nil
}

func (s *Service) lockRating(ctx context.Context, q *store.Queries, id, actor uuid.UUID) (store.GetRatingForUpdateRow, error) {
	row, err := q.GetRatingForUpdate(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrNotFound
	}
	if err != nil {
		return row, fmt.Errorf("load rating: %w", err)
	}
	if row.RatedUser == actor {
		return row, ErrSelfAction
	}
	return row, nil
}

func audit(ctx context.Context, q *store.Queries, action string, actor, ratingID uuid.UUID, requestID string, now time.Time) error {
	target := "rating:" + ratingID.String()
	err := q.InsertAuditEventWithTarget(ctx, store.InsertAuditEventWithTargetParams{
		Action: action, UserID: new(actor), RequestID: requestID, Ip: netip.IPv4Unspecified(), Target: new(target), Now: now,
	})
	if err != nil {
		return fmt.Errorf("write audit: %w", err)
	}
	return nil
}

// Nullify removes a rating from the score.
func (s *Service) Nullify(ctx context.Context, id, actor uuid.UUID, reason, requestID string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" || len(reason) > maxCommentLen {
		return ErrReasonRequired
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := s.lockRating(ctx, q, id, actor)
		if err != nil {
			return err
		}
		if row.NullifiedAt != nil {
			return ErrAlreadyDone
		}
		if err := q.NullifyRating(ctx, store.NullifyRatingParams{Now: new(now), Actor: new(actor), Reason: new(reason), ID: id}); err != nil {
			return fmt.Errorf("nullify rating: %w", err)
		}
		if _, err := q.RecalculateRating(ctx, store.RecalculateRatingParams{Now: now, UserID: row.RatedUser}); err != nil {
			return fmt.Errorf("recalculate rating: %w", err)
		}
		return audit(ctx, q, "rating.nullified", actor, id, requestID, now)
	})
}

// Reinstate returns a nullified rating to the score, under the original rules.
func (s *Service) Reinstate(ctx context.Context, id, actor uuid.UUID, requestID string) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := s.lockRating(ctx, q, id, actor)
		if err != nil {
			return err
		}
		if row.NullifiedAt == nil {
			return ErrAlreadyDone
		}
		include, exclusion := inclusion(row.Score, row.ReasonTags)
		if err := q.ReinstateRating(ctx, store.ReinstateRatingParams{IncludeInScore: include, ExclusionReason: exclusion, ID: id}); err != nil {
			return fmt.Errorf("reinstate rating: %w", err)
		}
		if _, err := q.RecalculateRating(ctx, store.RecalculateRatingParams{Now: now, UserID: row.RatedUser}); err != nil {
			return fmt.Errorf("recalculate rating: %w", err)
		}
		return audit(ctx, q, "rating.reinstated", actor, id, requestID, now)
	})
}
