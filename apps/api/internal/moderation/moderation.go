// Package moderation handles reports against accounts and the penalties that follow.
package moderation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	maxDescription = 2000
	maxReasonText  = 1000
	reportsPerDay  = 10

	StatusSubmitted   = "submitted"
	StatusTriaged     = "triaged"
	StatusUnderReview = "under_review"
	StatusResolved    = "resolved"
	StatusDismissed   = "dismissed"

	sourceInApp  = "in_app"
	sourceSystem = "system"
)

// Errors returned to callers.
var (
	ErrNotFound           = errors.New("not found")
	ErrInvalidCategory    = errors.New("report category is not valid")
	ErrInvalidDescription = errors.New("description is not valid")
	ErrNotParticipant     = errors.New("account was not on this ride")
	ErrNoOtherParty       = errors.New("ride has no other party to report")
	ErrWrongParty         = errors.New("category does not apply to this person")
	ErrRateLimited        = errors.New("too many reports")
	ErrInvalidDecision    = errors.New("decision is not valid")
	ErrInvalidStatus      = errors.New("status is not valid")
	ErrReportClosed       = errors.New("report is already closed")
	ErrConflictOfInterest = errors.New("staff cannot act on a case involving themselves")
	ErrInvalidEnd         = errors.New("suspension end is not valid")
	ErrEnforcementClosed  = errors.New("enforcement is no longer active")
)

// Config holds the dependencies of a Service.
type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
}

// Service implements reports and enforcement.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	now     func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{pool: cfg.Pool, queries: store.New(cfg.Pool), now: cfg.Now}
}

// Category is a kind of report.
type Category struct {
	Slug, Label, AppliesTo string
}

// Categories lists what a user can report.
func (s *Service) Categories(ctx context.Context) ([]Category, error) {
	rows, err := s.queries.ListReportCategories(ctx)
	if err != nil {
		return nil, fmt.Errorf("list categories: %w", err)
	}
	out := make([]Category, len(rows))
	for i, row := range rows {
		out[i] = Category{Slug: row.Slug, Label: row.Label, AppliesTo: row.AppliesTo}
	}
	return out, nil
}

// Report is a report as staff see it.
type Report struct {
	ID            uuid.UUID
	ReporterID    *uuid.UUID
	ReportedID    uuid.UUID
	Category      string
	Status        string
	Severity      int32
	Source        string
	IncidentType  string
	RideID        *uuid.UUID
	DisputeType   *string
	Description   string
	Outcome       *string
	OutcomeDetail *string
	CreatedAt     time.Time
}

// Submission is a report filed by a user about someone on their ride.
type Submission struct {
	ReporterID   uuid.UUID
	RideID       uuid.UUID
	Category     string
	Description  string
	IncidentType string

	DisputeType         *string
	RequestedResolution *string
}

// Filed identifies a report that now exists.
type Filed struct {
	ID        uuid.UUID
	Status    string
	CreatedAt time.Time
}

// otherParty returns who a report on this ride is about. The server decides
// this from the ride, so a client can never aim a report at a stranger.
func otherParty(ride store.GetRidePartiesRow, reporterID uuid.UUID) (uuid.UUID, bool, error) {
	switch {
	case ride.RiderID == reporterID && ride.DriverID != nil:
		return *ride.DriverID, true, nil
	case ride.DriverID != nil && *ride.DriverID == reporterID:
		return ride.RiderID, false, nil
	case ride.RiderID == reporterID:
		return uuid.Nil, false, ErrNoOtherParty
	default:
		return uuid.Nil, false, ErrNotParticipant
	}
}

func cleanDescription(raw string) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" || len(text) > maxDescription {
		return "", ErrInvalidDescription
	}
	return text, nil
}

// Submit files a report.
func (s *Service) Submit(ctx context.Context, sub Submission) (Filed, error) {
	var filed Filed
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "report:"+sub.ReporterID.String()); err != nil {
			return fmt.Errorf("lock reporter: %w", err)
		}
		count, err := q.CountReportsSince(ctx, store.CountReportsSinceParams{ReporterID: new(sub.ReporterID), Since: s.now().Add(-24 * time.Hour)})
		if err != nil {
			return fmt.Errorf("count reports: %w", err)
		}
		if count >= reportsPerDay {
			return ErrRateLimited
		}
		filed, err = s.SubmitInTx(ctx, q, sub)
		return err
	})
	return filed, err
}

// SubmitInTx files a report inside the caller's transaction.
func (s *Service) SubmitInTx(ctx context.Context, q *store.Queries, sub Submission) (Filed, error) {
	description, err := cleanDescription(sub.Description)
	if err != nil {
		return Filed{}, err
	}
	category, err := q.GetReportCategory(ctx, sub.Category)
	if errors.Is(err, pgx.ErrNoRows) {
		return Filed{}, ErrInvalidCategory
	}
	if err != nil {
		return Filed{}, fmt.Errorf("load category: %w", err)
	}
	ride, err := q.GetRideParties(ctx, sub.RideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Filed{}, ErrNotFound
	}
	if err != nil {
		return Filed{}, fmt.Errorf("load ride: %w", err)
	}
	reported, reportedIsDriver, err := otherParty(ride, sub.ReporterID)
	if err != nil {
		return Filed{}, err
	}
	if category.AppliesTo == "driver" && !reportedIsDriver {
		return Filed{}, ErrWrongParty
	}
	incident := sub.IncidentType
	if incident == "" {
		incident = "conduct"
	}
	now := s.now()
	row, err := q.InsertReport(ctx, store.InsertReportParams{
		ID: uuid.New(), ReporterID: new(sub.ReporterID), ReportedID: reported, Category: category.Slug,
		Severity: category.DefaultSeverity, Source: sourceInApp, IncidentType: incident, RideID: new(ride.ID),
		DisputeType: sub.DisputeType, RequestedResolution: sub.RequestedResolution, Description: description, Now: now,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// The same person already reported this ride for this reason. A repeat is
		// not a second incident, so the original report is the answer.
		existing, err := q.GetExistingRideReport(ctx, store.GetExistingRideReportParams{ReporterID: new(sub.ReporterID), RideID: new(ride.ID), Category: category.Slug})
		if err != nil {
			return Filed{}, fmt.Errorf("load existing report: %w", err)
		}
		return Filed{ID: existing.ID, Status: existing.Status, CreatedAt: existing.CreatedAt}, nil
	}
	if err != nil {
		return Filed{}, fmt.Errorf("insert report: %w", err)
	}
	return Filed{ID: row.ID, Status: row.Status, CreatedAt: row.CreatedAt}, nil
}

// SystemReport is raised by the platform itself.
type SystemReport struct {
	ReportedID   uuid.UUID
	Category     string
	SignalKey    string
	Severity     int32
	IncidentType string
	Description  string
	Cooldown     time.Duration
}

// RaiseSystemReport files a report unless the same signal is open or recent.
func (s *Service) RaiseSystemReport(ctx context.Context, q *store.Queries, r SystemReport) error {
	now := s.now()
	exists, err := q.SignalReportExists(ctx, store.SignalReportExistsParams{ReportedID: r.ReportedID, SignalKey: new(r.SignalKey), Since: now.Add(-r.Cooldown)})
	if err != nil {
		return fmt.Errorf("check signal: %w", err)
	}
	if exists {
		return nil
	}
	_, err = q.InsertReport(ctx, store.InsertReportParams{
		ID: uuid.New(), ReportedID: r.ReportedID, Category: r.Category, Severity: r.Severity, Source: sourceSystem,
		IncidentType: r.IncidentType, SignalKey: new(r.SignalKey), Description: r.Description, Now: now,
	})
	if err != nil {
		return fmt.Errorf("raise report: %w", err)
	}
	return nil
}
