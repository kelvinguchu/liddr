// Package disputes handles complaints about a ride and any compensation owed.
package disputes

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	submissionWindow = 48 * time.Hour
	perRideLimit     = 3
	perWeekLimit     = 10
	maxResolutionLen = 200
)

// Errors returned to callers.
var (
	ErrInvalidType     = errors.New("dispute type is not valid")
	ErrRideNotEligible = errors.New("ride cannot be disputed in this state")
	ErrWindowClosed    = errors.New("dispute window has closed")
	ErrRideLimit       = errors.New("too many disputes for this ride")
	ErrWeeklyLimit     = errors.New("too many disputes this week")
	ErrNotFound        = errors.New("dispute not found")
	ErrInvalidOutcome  = errors.New("outcome is not valid")
	ErrInvalidAmount   = errors.New("amount is not valid")
	ErrNotRefundable   = errors.New("only the rider who paid can be compensated")
	ErrAlreadySettled  = errors.New("compensation is already settled")
	ErrInvalidChannel  = errors.New("payment channel is not valid")
	ErrReferenceNeeded = errors.New("a payment reference is required")
	ErrSelfAction      = errors.New("staff cannot settle their own case")
)

type mapping struct {
	category, incident string
}

var types = map[string]mapping{
	"fare_dispute":         {"payment_dispute", "payment"},
	"driver_not_arrived":   {"cancellation_or_no_show_abuse", "conduct"},
	"wrong_route":          {"payment_dispute", "payment"},
	"safety_incident":      {"harassment_or_abuse", "safety"},
	"lost_item":            {"theft_or_lost_property_misconduct", "conduct"},
	"payment_not_received": {"payment_dispute", "payment"},
	"wrong_driver":         {"account_sharing_or_impersonation", "fraud"},
	"app_error":            {"other", "other"},
	"other":                {"other", "other"},
}

// activeRideTypes may be raised while the ride is still happening.
var activeRideTypes = map[string]bool{"safety_incident": true, "wrong_driver": true}

// Config holds the dependencies of a Service.
type Config struct {
	Pool       *pgxpool.Pool
	Moderation *moderation.Service
	Now        func() time.Time
}

// Service implements disputes.
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

// Submission is a dispute raised by a user.
type Submission struct {
	RequesterID         uuid.UUID
	RideID              uuid.UUID
	Type                string
	Description         string
	RequestedResolution *string
}

// Filed identifies a dispute that now exists.
type Filed struct {
	ID        uuid.UUID
	Status    string
	CreatedAt time.Time
}

func eligible(ride store.GetRidePartiesRow, disputeType string, now time.Time) error {
	switch ride.Status {
	case "accepted", "driver_arriving", "arrived", "in_progress":
		if !activeRideTypes[disputeType] {
			return ErrRideNotEligible
		}
		return nil
	case "completed", "cancelled":
		ended := ride.CompletedAt
		if ended == nil {
			ended = ride.CancelledAt
		}
		if ended == nil {
			return ErrRideNotEligible
		}
		if now.Sub(*ended) > submissionWindow {
			return ErrWindowClosed
		}
		return nil
	default:
		return ErrRideNotEligible
	}
}

// Submit raises a dispute. Limits are checked under a per-user lock, so parallel
// requests cannot slip past them.
func (s *Service) Submit(ctx context.Context, sub Submission) (Filed, error) {
	kind, ok := types[sub.Type]
	if !ok {
		return Filed{}, ErrInvalidType
	}
	var requested *string
	if sub.RequestedResolution != nil {
		text := strings.TrimSpace(*sub.RequestedResolution)
		if len(text) > maxResolutionLen {
			return Filed{}, ErrInvalidType
		}
		if text != "" {
			requested = &text
		}
	}
	now := s.now()
	var out Filed
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "dispute:"+sub.RequesterID.String()); err != nil {
			return fmt.Errorf("lock requester: %w", err)
		}
		ride, err := q.GetRideParties(ctx, sub.RideID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load ride: %w", err)
		}
		// Someone with no connection to the ride is refused by SubmitInTx, without
		// first being told what state a stranger's ride is in.
		if ride.RiderID == sub.RequesterID || (ride.DriverID != nil && *ride.DriverID == sub.RequesterID) {
			if err := eligible(ride, sub.Type, now); err != nil {
				return err
			}
		}
		if err := checkLimits(ctx, q, sub, now); err != nil {
			return err
		}
		filed, err := s.moderation.SubmitInTx(ctx, q, moderation.Submission{
			ReporterID: sub.RequesterID, RideID: sub.RideID, Category: kind.category, Description: sub.Description,
			IncidentType: kind.incident, DisputeType: new(sub.Type), RequestedResolution: requested,
		})
		if err != nil {
			return err
		}
		out = Filed{ID: filed.ID, Status: filed.Status, CreatedAt: filed.CreatedAt}
		return nil
	})
	return out, err
}

func checkLimits(ctx context.Context, q *store.Queries, sub Submission, now time.Time) error {
	perRide, err := q.CountDisputesForRide(ctx, store.CountDisputesForRideParams{ReporterID: new(sub.RequesterID), RideID: new(sub.RideID)})
	if err != nil {
		return fmt.Errorf("count ride disputes: %w", err)
	}
	if perRide >= perRideLimit {
		return ErrRideLimit
	}
	perWeek, err := q.CountDisputesSince(ctx, store.CountDisputesSinceParams{ReporterID: new(sub.RequesterID), Since: now.Add(-7 * 24 * time.Hour)})
	if err != nil {
		return fmt.Errorf("count weekly disputes: %w", err)
	}
	if perWeek >= perWeekLimit {
		return ErrWeeklyLimit
	}
	return nil
}

// Mine is a dispute as a party to it sees it. It carries no reporter identity
// and no text, because either party may be the accused.
type Mine struct {
	ID         uuid.UUID
	RideID     *uuid.UUID
	Type       string
	Status     string
	Outcome    *string
	OpenedByMe bool
	CreatedAt  time.Time
}

// ListMine returns disputes the user raised or may know about.
func (s *Service) ListMine(ctx context.Context, userID uuid.UUID, limit, offset int32) ([]Mine, error) {
	rows, err := s.queries.ListDisputesForUser(ctx, store.ListDisputesForUserParams{UserID: new(userID), RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list disputes: %w", err)
	}
	out := make([]Mine, len(rows))
	for i, r := range rows {
		disputeType := ""
		if r.DisputeType != nil {
			disputeType = *r.DisputeType
		}
		out[i] = Mine{ID: r.ID, RideID: r.RideID, Type: disputeType, Status: r.Status, Outcome: r.ResolutionOutcome, OpenedByMe: r.OpenedByMe, CreatedAt: r.CreatedAt}
	}
	return out, nil
}
