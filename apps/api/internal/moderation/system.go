package moderation

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

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
