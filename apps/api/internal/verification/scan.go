package verification

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/malware"
	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	scanLease       = 2 * time.Minute
	maxScanAttempts = 5
	pollInterval    = time.Second
	expiryInterval  = time.Hour
	workTimeout     = time.Minute

	messageUnsafe     = "This file failed our safety check. Please take a new photo and upload it again."
	messageUnreadable = "We could not read this file. Please upload it again."
)

// Run scans uploaded documents and enforces expiry until ctx ends.
func (s *Service) Run(ctx context.Context) {
	scan := time.NewTicker(pollInterval)
	defer scan.Stop()
	expiry := time.NewTicker(expiryInterval)
	defer expiry.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-scan.C:
			s.drainScans(ctx)
		case <-expiry.C:
			if err := s.ExpireDocuments(ctx); err != nil && ctx.Err() == nil {
				s.logger.LogAttrs(ctx, slog.LevelError, "document expiry failed", slog.Any("error", err))
			}
		}
	}
}

func (s *Service) drainScans(ctx context.Context) {
	if s.storage == nil || s.scanner == nil {
		return
	}
	for ctx.Err() == nil {
		worked, err := s.ScanNext(ctx)
		if err != nil && ctx.Err() == nil {
			s.logger.LogAttrs(ctx, slog.LevelError, "document scan failed", slog.Any("error", err))
			return
		}
		if !worked {
			return
		}
	}
}

// ScanNext processes one waiting document, reporting whether it found one. The
// lease is claimed and released in separate transactions so that no transaction
// is open while talking to storage or the scanner.
func (s *Service) ScanNext(ctx context.Context) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, workTimeout)
	defer cancel()
	now := s.now()
	claim, err := s.queries.ClaimDocumentForScan(ctx, store.ClaimDocumentForScanParams{LeaseUntil: new(now.Add(scanLease)), Now: new(now)})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("claim document: %w", err)
	}
	result, err := s.inspect(ctx, claim.StorageKey, claim.ContentType)
	if err != nil {
		if claim.ScanAttempts < maxScanAttempts {
			// The lease stays in place, so the next attempt waits for it to lapse.
			return true, fmt.Errorf("inspect document: %w", err)
		}
		result = inspection{scanStatus: scanFailed, reason: messageUnreadable}
	}
	return true, s.recordScan(ctx, claim.ID, claim.DriverID, result)
}

type inspection struct {
	scanStatus string
	signature  *string
	reason     string
}

// inspect returns an error only when no conclusion was reached. A file that is
// not what it claims to be is a conclusion, and is treated as unsafe.
func (s *Service) inspect(ctx context.Context, key, contentType string) (inspection, error) {
	data, err := s.storage.Read(ctx, key, maxFileBytes)
	if errors.Is(err, storage.ErrTooLarge) || errors.Is(err, storage.ErrNotFound) {
		return inspection{scanStatus: scanFailed, reason: messageUnreadable}, nil
	}
	if err != nil {
		return inspection{}, fmt.Errorf("read object: %w", err)
	}
	// The stored content type is only what the client declared.
	if kind, ok := allowedTypes[contentType]; !ok || !strings.HasPrefix(string(data), kind.magic) {
		return inspection{scanStatus: scanFailed, reason: messageUnreadable}, nil
	}
	verdict, err := s.scanner.Scan(ctx, data)
	if errors.Is(err, malware.ErrUnavailable) {
		return inspection{}, fmt.Errorf("scan object: %w", err)
	}
	if err != nil {
		return inspection{}, fmt.Errorf("scan object: %w", err)
	}
	if !verdict.Clean {
		return inspection{scanStatus: scanInfected, signature: new(verdict.Signature), reason: messageUnsafe}, nil
	}
	return inspection{scanStatus: scanClean}, nil
}

func (s *Service) recordScan(ctx context.Context, documentID, driverID uuid.UUID, result inspection) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, driverID); err != nil {
			return err
		}
		doc, err := q.GetDocumentForUpdate(ctx, documentID)
		if err != nil {
			return fmt.Errorf("load document: %w", err)
		}
		// Replaced while scanning, or already finished by an earlier delivery.
		if doc.ScanStatus != scanPending {
			return nil
		}
		status, keepScan := docPendingReview, doc.Status != docScanning
		var reason *string
		if result.scanStatus != scanClean {
			status, reason = statusRejected, new(result.reason)
		}
		if keepScan {
			status = doc.Status
		}
		err = q.RecordDocumentScan(ctx, store.RecordDocumentScanParams{
			Status: status, ScanStatus: result.scanStatus, ScanSignature: result.signature,
			RejectionReason: reason, Now: new(now), ID: documentID,
		})
		if err != nil {
			return fmt.Errorf("record scan: %w", err)
		}
		err = recordReview(ctx, q, reviewEntry{
			applicationID: doc.ApplicationID, documentID: new(documentID), driverID: driverID,
			decision: "scan_" + result.scanStatus, before: doc.Status, after: status, reason: reason, at: now,
		})
		if err != nil {
			return err
		}
		if result.scanStatus == scanClean && !keepScan {
			return s.promoteIfComplete(ctx, q, doc.ApplicationID, driverID, now)
		}
		return notify(ctx, q, driverID, status)
	})
}

// promoteIfComplete moves an application into review once every required
// document exists and has passed scanning.
func (s *Service) promoteIfComplete(ctx context.Context, q *store.Queries, applicationID, driverID uuid.UUID, now time.Time) error {
	open, err := q.GetOpenApplication(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("load application: %w", err)
	}
	if open.ID != applicationID || open.Status == statusUnderReview {
		return nil
	}
	missing, err := q.CountRequirementsNotMet(ctx, store.CountRequirementsNotMetParams{
		DriverID: driverID, Statuses: []string{docPendingReview, docValidated}, Today: new(s.today()),
	})
	if err != nil {
		return fmt.Errorf("count missing documents: %w", err)
	}
	if missing > 0 {
		return notify(ctx, q, driverID, open.Status)
	}
	if err := q.SetApplicationStatus(ctx, store.SetApplicationStatusParams{Status: statusUnderReview, Now: now, ID: applicationID}); err != nil {
		return fmt.Errorf("promote application: %w", err)
	}
	driver, err := q.GetVerificationDriver(ctx, driverID)
	if err != nil {
		return fmt.Errorf("load driver: %w", err)
	}
	// A driver renewing a document stays approved and keeps working meanwhile.
	if driver.VerificationStatus != statusApproved {
		err := q.SetDriverVerification(ctx, store.SetDriverVerificationParams{Status: statusUnderReview, Now: now, UserID: driverID})
		if err != nil {
			return fmt.Errorf("update driver: %w", err)
		}
	}
	return notify(ctx, q, driverID, statusUnderReview)
}
