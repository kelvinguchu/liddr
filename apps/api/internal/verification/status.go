package verification

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Requirement is one document a driver must provide and where it stands.
type Requirement struct {
	DocumentType   string
	Label          string
	Required       bool
	RequiresExpiry bool
	Document       *Document
}

// Status is everything a driver needs to see about their verification.
type Status struct {
	DriverStatus string
	PlateNumber  *string
	Application  *Application
	Requirements []Requirement
}

// GetStatus reports a driver's verification progress.
func (s *Service) GetStatus(ctx context.Context, driverID uuid.UUID) (Status, error) {
	driver, err := s.queries.GetVerificationDriver(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Status{}, ErrProfileMissing
	}
	if err != nil {
		return Status{}, fmt.Errorf("load driver: %w", err)
	}
	out := Status{DriverStatus: driver.VerificationStatus, PlateNumber: driver.PlateNumber}

	latest, err := s.queries.GetLatestApplication(ctx, driverID)
	switch {
	case err == nil:
		out.Application = &Application{
			ID: latest.ID, Status: latest.Status, DecidedAt: latest.DecidedAt,
			DecisionReason: latest.DecisionReason, CreatedAt: latest.CreatedAt,
		}
	case !errors.Is(err, pgx.ErrNoRows):
		return Status{}, fmt.Errorf("load application: %w", err)
	}

	requirements, err := s.queries.ListVerificationRequirements(ctx)
	if err != nil {
		return Status{}, fmt.Errorf("list requirements: %w", err)
	}
	live, err := s.queries.ListLiveDocuments(ctx, driverID)
	if err != nil {
		return Status{}, fmt.Errorf("list documents: %w", err)
	}
	documents := make(map[string]Document, len(live))
	for _, row := range live {
		documents[row.DocumentType] = documentFromLive(row)
	}
	out.Requirements = make([]Requirement, len(requirements))
	for i, r := range requirements {
		out.Requirements[i] = Requirement{DocumentType: r.DocumentType, Label: r.Label, Required: r.Required, RequiresExpiry: r.RequiresExpiry}
		if doc, ok := documents[r.DocumentType]; ok {
			out.Requirements[i].Document = &doc
		}
	}
	return out, nil
}

func documentFromLive(row store.ListLiveDocumentsRow) Document {
	return Document{
		ID: row.ID, DocumentType: row.DocumentType, Version: row.Version, Status: row.Status,
		ExpiresOn: row.ExpiresOn, RejectionReason: row.RejectionReason, CreatedAt: row.CreatedAt,
	}
}

// QueueItem is one application in the staff queue. Phone is masked, because
// most of the queue's readers do not need the number to do their work.
type QueueItem struct {
	Application  Application
	DriverID     uuid.UUID
	DriverStatus string
	PlateNumber  *string
	PhoneMasked  string
}

func maskPhone(phone string) string {
	if len(phone) < 4 {
		return "****"
	}
	return "****" + phone[len(phone)-4:]
}

// ListApplications returns applications in one status, oldest first.
func (s *Service) ListApplications(ctx context.Context, status string, limit, offset int32) ([]QueueItem, error) {
	rows, err := s.queries.ListApplications(ctx, store.ListApplicationsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list applications: %w", err)
	}
	items := make([]QueueItem, len(rows))
	for i, row := range rows {
		items[i] = QueueItem{
			Application:  Application{ID: row.ID, Status: row.Status, DecidedAt: row.DecidedAt, DecisionReason: row.DecisionReason, CreatedAt: row.CreatedAt},
			DriverID:     row.DriverID,
			DriverStatus: row.DriverStatus,
			PlateNumber:  row.PlateNumber,
			PhoneMasked:  maskPhone(row.Phone),
		}
	}
	return items, nil
}

// ApplicationDetail is one application and the driver's current documents.
type ApplicationDetail struct {
	QueueItem
	Documents []ReviewDocument
}

// ReviewDocument is a document as a reviewer sees it.
type ReviewDocument struct {
	Document
	ContentType string
	ScanStatus  string
}

// GetApplication loads an application for review.
func (s *Service) GetApplication(ctx context.Context, id uuid.UUID) (ApplicationDetail, error) {
	row, err := s.queries.GetApplication(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return ApplicationDetail{}, ErrNotFound
	}
	if err != nil {
		return ApplicationDetail{}, fmt.Errorf("load application: %w", err)
	}
	live, err := s.queries.ListLiveDocuments(ctx, row.DriverID)
	if err != nil {
		return ApplicationDetail{}, fmt.Errorf("list documents: %w", err)
	}
	out := ApplicationDetail{
		Application:  Application{ID: row.ID, Status: row.Status, DecidedAt: row.DecidedAt, DecisionReason: row.DecisionReason, CreatedAt: row.CreatedAt},
		DriverID:     row.DriverID,
		DriverStatus: row.DriverStatus,
		PlateNumber:  row.PlateNumber,
		PhoneMasked:  maskPhone(row.Phone),
		Documents:    make([]ReviewDocument, len(live)),
	}
	for i, doc := range live {
		out.Documents[i] = ReviewDocument{Document: documentFromLive(doc), ContentType: doc.ContentType, ScanStatus: doc.ScanStatus}
	}
	return out, nil
}

// DownloadURL returns a short-lived link to a document's file and records who
// asked. Only files that passed scanning can be opened by staff.
func (s *Service) DownloadURL(ctx context.Context, documentID uuid.UUID, actor Actor) (string, time.Time, error) {
	if s.storage == nil {
		return "", time.Time{}, ErrUnavailable
	}
	doc, err := s.queries.GetDocument(ctx, documentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", time.Time{}, ErrNotFound
	}
	if err != nil {
		return "", time.Time{}, fmt.Errorf("load document: %w", err)
	}
	if doc.ScanStatus != scanClean {
		return "", time.Time{}, ErrDocumentNotReady
	}
	url, err := s.storage.SignDownload(doc.StorageKey, downloadTTL)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("sign download: %w", err)
	}
	now := s.now()
	target := "verification_document:" + documentID.String()
	err = s.queries.InsertAuditEventWithTarget(ctx, store.InsertAuditEventWithTargetParams{
		Action: "verification.document_viewed", UserID: new(actor.UserID), RequestID: actor.RequestID,
		Ip: actor.IP, Target: new(target), Now: now,
	})
	if err != nil {
		return "", time.Time{}, fmt.Errorf("audit document view: %w", err)
	}
	return url, now.Add(downloadTTL), nil
}
