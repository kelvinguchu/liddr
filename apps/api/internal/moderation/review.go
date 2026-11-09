package moderation

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Decisions a reviewer can make.
const (
	DecisionNeedsInfo  = "needs_more_info"
	DecisionNoAction   = "no_action"
	DecisionWarning    = "warning"
	DecisionSuspension = "temporary_suspension"
	DecisionBan        = "permanent_ban"
	DecisionEscalate   = "escalate"
	DecisionDismiss    = "dismiss"
)

func open(status string) bool {
	return status == StatusSubmitted || status == StatusTriaged || status == StatusUnderReview
}

func toReport(row store.GetReportRow) Report {
	return Report{
		ID: row.ID, ReporterID: row.ReporterID, ReportedID: row.ReportedID, Category: row.Category, Status: row.Status,
		Severity: row.Severity, Source: row.Source, IncidentType: row.IncidentType, RideID: row.RideID,
		DisputeType: row.DisputeType, Description: row.Description, Outcome: row.ResolutionOutcome,
		OutcomeDetail: row.ResolutionSummary, CreatedAt: row.CreatedAt,
	}
}

// ListReports returns open work in one status, most severe first.
func (s *Service) ListReports(ctx context.Context, status string, limit, offset int32) ([]Report, error) {
	rows, err := s.queries.ListReports(ctx, store.ListReportsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list reports: %w", err)
	}
	out := make([]Report, len(rows))
	for i, row := range rows {
		out[i] = Report{
			ID: row.ID, ReporterID: row.ReporterID, ReportedID: row.ReportedID, Category: row.Category, Status: row.Status,
			Severity: row.Severity, Source: row.Source, IncidentType: row.IncidentType, RideID: row.RideID,
			DisputeType: row.DisputeType, CreatedAt: row.CreatedAt,
		}
	}
	return out, nil
}

// GetReport loads one report, including its text, for staff.
func (s *Service) GetReport(ctx context.Context, id uuid.UUID) (Report, error) {
	row, err := s.queries.GetReport(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return Report{}, ErrNotFound
	}
	if err != nil {
		return Report{}, fmt.Errorf("load report: %w", err)
	}
	return toReport(row), nil
}

func involved(row store.GetReportForUpdateRow, actor uuid.UUID) bool {
	return row.ReportedID == actor || (row.ReporterID != nil && *row.ReporterID == actor)
}

// Triage claims a report for review.
func (s *Service) Triage(ctx context.Context, id uuid.UUID, status string, actor uuid.UUID) error {
	if status != StatusTriaged && status != StatusUnderReview {
		return ErrInvalidStatus
	}
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetReportForUpdate(ctx, id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load report: %w", err)
		}
		if involved(row, actor) {
			return ErrConflictOfInterest
		}
		if !open(row.Status) {
			return ErrReportClosed
		}
		now := s.now()
		if err := q.TriageReport(ctx, store.TriageReportParams{Status: status, Now: now, ReviewerID: new(actor), ID: id}); err != nil {
			return fmt.Errorf("triage report: %w", err)
		}
		return reviewRow(ctx, q, id, actor, "triage", row.Status, status, nil, nil, now)
	})
}

func reviewRow(ctx context.Context, q *store.Queries, report, actor uuid.UUID, decision, before, after string, code, notes *string, now time.Time) error {
	err := q.InsertReportReview(ctx, store.InsertReportReviewParams{
		ReportID: report, ReviewerID: new(actor), Decision: decision, StatusBefore: before, StatusAfter: after,
		ReasonCode: code, Notes: notes, Now: now,
	})
	if err != nil {
		return fmt.Errorf("record review: %w", err)
	}
	return nil
}

// Decision is a reviewer's ruling on a report.
type Decision struct {
	Decision   string
	ReasonCode *string
	Notes      *string
	EndsAt     *time.Time
	Actor      uuid.UUID
	// Outcome overrides the recorded outcome, for disputes.
	Outcome *string
}

// Review records a ruling and applies any penalty, all or nothing.
func (s *Service) Review(ctx context.Context, id uuid.UUID, d Decision) error {
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		_, err := s.ReviewInTx(ctx, q, id, d)
		return err
	})
}

// ReviewInTx records a ruling inside the caller's transaction and returns the report.
func (s *Service) ReviewInTx(ctx context.Context, q *store.Queries, id uuid.UUID, d Decision) (store.GetReportForUpdateRow, error) {
	if d.Notes != nil && len(strings.TrimSpace(*d.Notes)) > maxReasonText {
		return store.GetReportForUpdateRow{}, ErrInvalidDescription
	}
	row, err := q.GetReportForUpdate(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrNotFound
	}
	if err != nil {
		return row, fmt.Errorf("load report: %w", err)
	}
	if involved(row, d.Actor) {
		return row, ErrConflictOfInterest
	}
	if !open(row.Status) {
		return row, ErrReportClosed
	}
	now := s.now()
	status, outcome, resolved := StatusResolved, new(d.Decision), new(now)
	switch d.Decision {
	case DecisionNeedsInfo:
		status, outcome, resolved = StatusUnderReview, nil, nil
	case DecisionEscalate:
		status, outcome, resolved = StatusUnderReview, new("escalated"), nil
	case DecisionDismiss:
		status, outcome = StatusDismissed, new(DecisionNoAction)
	case DecisionNoAction, DecisionWarning, DecisionSuspension, DecisionBan:
	default:
		return row, ErrInvalidDecision
	}
	if d.Outcome != nil {
		outcome = d.Outcome
	}
	err = q.ResolveReport(ctx, store.ResolveReportParams{
		Status: status, ReviewerID: new(d.Actor), ResolvedAt: resolved, Outcome: outcome, Summary: d.Notes, Now: now, ID: id,
	})
	if err != nil {
		return row, fmt.Errorf("resolve report: %w", err)
	}
	if err := reviewRow(ctx, q, id, d.Actor, d.Decision, row.Status, status, d.ReasonCode, d.Notes, now); err != nil {
		return row, err
	}
	switch d.Decision {
	case DecisionWarning, DecisionSuspension, DecisionBan:
		code := "report_" + d.Decision
		if d.ReasonCode != nil && *d.ReasonCode != "" {
			code = *d.ReasonCode
		}
		_, err := s.applyInTx(ctx, q, Penalty{
			UserID: row.ReportedID, ReportID: new(id), Actor: d.Actor, Action: d.Decision,
			ReasonCode: code, ReasonText: d.Notes, EndsAt: d.EndsAt,
		})
		if err != nil {
			return row, err
		}
	}
	return row, nil
}
