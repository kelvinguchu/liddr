// Package ratings records what riders and drivers think of each other.
package ratings

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	maxTags       = 5
	maxCommentLen = 200

	guardrailWindow  = 30 * 24 * time.Hour
	guardrailMinimum = 20
)

var tagPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{1,39}$`)

// Tags that describe something outside the rated person's control. A low score
// citing one of these does not count against them.
var outOfControlTags = []string{"traffic", "app_issue", "gps_issue", "wrong_pickup_pin", "co_rider_behavior"}

// Errors returned to callers.
var (
	ErrNotRateable     = errors.New("ride cannot be rated")
	ErrInvalidScore    = errors.New("score must be one to five")
	ErrReasonsRequired = errors.New("a score below five needs a reason")
	ErrInvalidTags     = errors.New("reason tags are not valid")
	ErrInvalidComment  = errors.New("comment is too long")
	ErrNotFound        = errors.New("rating not found")
	ErrAlreadyDone     = errors.New("rating is already in that state")
	ErrReasonRequired  = errors.New("a reason is required")
	ErrSelfAction      = errors.New("staff cannot change their own ratings")
)

// Config holds the dependencies of a Service.
type Config struct {
	Pool       *pgxpool.Pool
	Moderation *moderation.Service
	Now        func() time.Time
}

// Service implements rating.
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

// Pending is a rating the user is still invited to give.
type Pending struct {
	RideID      uuid.UUID
	RaterRole   string
	DueAt       time.Time
	CompletedAt *time.Time
}

// ListPending returns the ratings a user can still give.
func (s *Service) ListPending(ctx context.Context, userID uuid.UUID) ([]Pending, error) {
	rows, err := s.queries.ListPendingRatings(ctx, store.ListPendingRatingsParams{RatedBy: userID, Now: s.now()})
	if err != nil {
		return nil, fmt.Errorf("list pending ratings: %w", err)
	}
	out := make([]Pending, len(rows))
	for i, r := range rows {
		out[i] = Pending{RideID: r.RideID, RaterRole: r.RaterRole, DueAt: r.DueAt, CompletedAt: r.CompletedAt}
	}
	return out, nil
}

// Submission is one rating.
type Submission struct {
	RideID  uuid.UUID
	RaterID uuid.UUID
	Score   int32
	Tags    []string
	Comment *string
}

func cleanTags(raw []string) ([]string, error) {
	tags := make([]string, 0, len(raw))
	for _, tag := range raw {
		tag = strings.ToLower(strings.TrimSpace(tag))
		if !tagPattern.MatchString(tag) {
			return nil, ErrInvalidTags
		}
		if !slices.Contains(tags, tag) {
			tags = append(tags, tag)
		}
	}
	if len(tags) > maxTags {
		return nil, ErrInvalidTags
	}
	return tags, nil
}

// inclusion decides whether a rating counts toward the score.
func inclusion(score int32, tags []string) (bool, *string) {
	if score < 5 && slices.ContainsFunc(tags, func(tag string) bool { return slices.Contains(outOfControlTags, tag) }) {
		return false, new("out_of_control_factor")
	}
	return true, nil
}

func (s *Service) pendingAction(ctx context.Context, q *store.Queries, rideID, raterID uuid.UUID, now time.Time) (store.GetRatingActionForUpdateRow, error) {
	action, err := q.GetRatingActionForUpdate(ctx, store.GetRatingActionForUpdateParams{RideID: rideID, RatedBy: raterID})
	if errors.Is(err, pgx.ErrNoRows) {
		return action, ErrNotRateable
	}
	if err != nil {
		return action, fmt.Errorf("load rating action: %w", err)
	}
	if action.Status != "pending" || !now.Before(action.DueAt) {
		return action, ErrNotRateable
	}
	return action, nil
}

// Rate records a rating and updates the rated person's score.
func (s *Service) Rate(ctx context.Context, sub Submission) error {
	if sub.Score < 1 || sub.Score > 5 {
		return ErrInvalidScore
	}
	tags, err := cleanTags(sub.Tags)
	if err != nil {
		return err
	}
	if sub.Score < 5 && len(tags) == 0 {
		return ErrReasonsRequired
	}
	var comment *string
	if sub.Comment != nil {
		text := strings.TrimSpace(*sub.Comment)
		if len(text) > maxCommentLen {
			return ErrInvalidComment
		}
		if text != "" {
			comment = &text
		}
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		action, err := s.pendingAction(ctx, q, sub.RideID, sub.RaterID, now)
		if err != nil {
			return err
		}
		include, exclusion := inclusion(sub.Score, tags)
		_, err = q.InsertRating(ctx, store.InsertRatingParams{
			ID: uuid.New(), RideID: sub.RideID, RatedBy: sub.RaterID, RatedUser: action.RatedUser, Score: sub.Score,
			ReasonTags: tags, Comment: comment, IncludeInScore: include, ExclusionReason: exclusion, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert rating: %w", err)
		}
		err = q.ResolveRatingAction(ctx, store.ResolveRatingActionParams{Status: "rated", Now: new(now), RideID: sub.RideID, RatedBy: sub.RaterID})
		if err != nil {
			return fmt.Errorf("resolve action: %w", err)
		}
		stats, err := q.RecalculateRating(ctx, store.RecalculateRatingParams{Now: now, UserID: action.RatedUser})
		if err != nil {
			return fmt.Errorf("recalculate rating: %w", err)
		}
		if err := s.checkLowRating(ctx, q, action.RatedUser, stats.RatingCenti, stats.RatingCount, now); err != nil {
			return err
		}
		if sub.Score == 5 && include {
			return s.checkManipulation(ctx, q, action.RatedUser, sub.RaterID, now)
		}
		return nil
	})
}

// Skip declines to rate.
func (s *Service) Skip(ctx context.Context, rideID, raterID uuid.UUID) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if _, err := s.pendingAction(ctx, q, rideID, raterID, now); err != nil {
			return err
		}
		err := q.ResolveRatingAction(ctx, store.ResolveRatingActionParams{Status: "skipped", Now: new(now), RideID: rideID, RatedBy: raterID})
		if err != nil {
			return fmt.Errorf("resolve action: %w", err)
		}
		return nil
	})
}
