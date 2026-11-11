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

// Document is one version of a required document.
type Document struct {
	ID              uuid.UUID
	DocumentType    string
	Version         int32
	Status          string
	ExpiresOn       *time.Time
	RejectionReason *string
	CreatedAt       time.Time
}

// SubmitDocument records an uploaded file for scanning. The object is checked
// against what was promised before any transaction starts.
func (s *Service) SubmitDocument(ctx context.Context, driverID, uploadID uuid.UUID, expiresOn *time.Time) (Document, error) {
	if s.storage == nil || s.scanner == nil {
		return Document{}, ErrUnavailable
	}
	upload, err := s.queries.GetUpload(ctx, store.GetUploadParams{ID: uploadID, DriverID: driverID})
	if errors.Is(err, pgx.ErrNoRows) {
		return Document{}, ErrNotFound
	}
	if err != nil {
		return Document{}, fmt.Errorf("load upload: %w", err)
	}
	now := s.now()
	if upload.ConsumedAt != nil || !now.Before(upload.ExpiresAt) {
		return Document{}, ErrUploadExpired
	}
	object, err := s.storage.Stat(ctx, upload.StorageKey)
	if err != nil {
		return Document{}, errors.Join(ErrUploadMissing, err)
	}
	if object.Size != upload.SizeBytes || object.ContentType != upload.ContentType {
		return Document{}, ErrUploadMissing
	}

	var out Document
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, driverID); err != nil {
			return err
		}
		requirement, err := q.GetVerificationRequirement(ctx, upload.DocumentType)
		if err != nil {
			return fmt.Errorf("load requirement: %w", err)
		}
		if requirement.RequiresExpiry && (expiresOn == nil || !expiresOn.After(s.today())) {
			return ErrExpiryRequired
		}
		application, err := q.GetOpenApplication(ctx, driverID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoOpenApplication
		}
		if err != nil {
			return fmt.Errorf("load application: %w", err)
		}
		// Spending the upload first means a repeat of this request stops here.
		consumed, err := q.ConsumeUpload(ctx, store.ConsumeUploadParams{Now: new(now), ID: uploadID})
		if err != nil {
			return fmt.Errorf("consume upload: %w", err)
		}
		if consumed == 0 {
			return ErrUploadExpired
		}
		last, err := q.LastDocumentVersion(ctx, store.LastDocumentVersionParams{DriverID: driverID, DocumentType: upload.DocumentType})
		if err != nil {
			return fmt.Errorf("load version: %w", err)
		}
		err = q.SupersedeLiveDocument(ctx, store.SupersedeLiveDocumentParams{Now: now, DriverID: driverID, DocumentType: upload.DocumentType})
		if err != nil {
			return fmt.Errorf("supersede document: %w", err)
		}
		row, err := q.InsertDocument(ctx, store.InsertDocumentParams{
			ID: uuid.New(), ApplicationID: application.ID, DriverID: driverID, DocumentType: upload.DocumentType,
			Version: last + 1, StorageKey: upload.StorageKey, ContentType: upload.ContentType,
			SizeBytes: upload.SizeBytes, ExpiresOn: expiresOn, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert document: %w", err)
		}
		out = Document{
			ID: row.ID, DocumentType: row.DocumentType, Version: row.Version, Status: row.Status,
			ExpiresOn: row.ExpiresOn, RejectionReason: row.RejectionReason, CreatedAt: row.CreatedAt,
		}
		return nil
	})
	if err != nil {
		return Document{}, err
	}
	return out, nil
}
