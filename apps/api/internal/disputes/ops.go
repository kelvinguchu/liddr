package disputes

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// OpsCase is a dispute with everything a reviewer needs.
type OpsCase struct {
	ID                  uuid.UUID
	ReporterID          *uuid.UUID
	ReportedID          uuid.UUID
	RideID              *uuid.UUID
	Type                string
	Status              string
	Severity            int32
	IncidentType        string
	RequestedResolution *string
	Description         string
	CreatedAt           time.Time
}

// ListCases returns disputes in one status, most severe first.
func (s *Service) ListCases(ctx context.Context, status string, limit, offset int32) ([]OpsCase, error) {
	rows, err := s.queries.ListDisputesForOps(ctx, store.ListDisputesForOpsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list disputes: %w", err)
	}
	out := make([]OpsCase, len(rows))
	for i, r := range rows {
		kind := ""
		if r.DisputeType != nil {
			kind = *r.DisputeType
		}
		out[i] = OpsCase{ID: r.ID, ReporterID: r.ReporterID, ReportedID: r.ReportedID, RideID: r.RideID, Type: kind, Status: r.Status, Severity: r.Severity, IncidentType: r.IncidentType, RequestedResolution: r.RequestedResolution, Description: r.Description, CreatedAt: r.CreatedAt}
	}
	return out, nil
}
