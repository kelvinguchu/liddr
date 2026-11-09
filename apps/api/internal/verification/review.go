package verification

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

const (
	maxReasonLength = 500

	decisionApprove  = "approve"
	decisionReject   = "reject"
	decisionResubmit = "request_resubmission"
	decisionSuspend  = "suspend"
)

func cleanReason(raw *string, required bool) (*string, error) {
	if raw == nil || strings.TrimSpace(*raw) == "" {
		if required {
			return nil, ErrReasonRequired
		}
		return nil, nil //nolint:nilnil // No reason is a valid result here.
	}
	reason := strings.TrimSpace(*raw)
	if len(reason) > maxReasonLength {
		return nil, ErrReasonRequired
	}
	return &reason, nil
}

// ReviewDocument records a reviewer's decision on one document.
func (s *Service) ReviewDocument(ctx context.Context, documentID uuid.UUID, decision string, rawReason *string, actor Actor) error {
	status := map[string]string{
		decisionApprove:  docValidated,
		decisionReject:   statusRejected,
		decisionResubmit: statusResubmit,
	}[decision]
	if status == "" {
		return ErrInvalidDecision
	}
	reason, err := cleanReason(rawReason, decision != decisionApprove)
	if err != nil {
		return err
	}
	peek, err := s.queries.GetDocument(ctx, documentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("load document: %w", err)
	}
	if peek.DriverID == actor.UserID {
		return ErrSelfReview
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, peek.DriverID); err != nil {
			return err
		}
		doc, err := q.GetDocumentForUpdate(ctx, documentID)
		if err != nil {
			return fmt.Errorf("load document: %w", err)
		}
		if doc.Status != docPendingReview || doc.ScanStatus != scanClean {
			return ErrDocumentNotReady
		}
		err = q.RecordDocumentReview(ctx, store.RecordDocumentReviewParams{
			Status: status, RejectionReason: reason, Now: new(now), ReviewedBy: new(actor.UserID), ID: documentID,
		})
		if err != nil {
			return fmt.Errorf("record decision: %w", err)
		}
		err = recordReview(ctx, q, reviewEntry{
			applicationID: doc.ApplicationID, documentID: new(documentID), driverID: doc.DriverID,
			reviewerID: new(actor.UserID), decision: decision, before: doc.Status, after: status, reason: reason, at: now,
		})
		if err != nil {
			return err
		}
		if decision != decisionApprove {
			if err := s.sendBack(ctx, q, doc.DriverID, now); err != nil {
				return err
			}
		}
		return notify(ctx, q, doc.DriverID, status)
	})
}

// BulkResult is the outcome for one document in a batch.
type BulkResult struct {
	DocumentID uuid.UUID
	Err        error
}

// ReviewDocuments applies one decision to many documents. Each is its own
// transaction, so one that cannot be reviewed does not undo the rest.
func (s *Service) ReviewDocuments(ctx context.Context, ids []uuid.UUID, decision string, reason *string, actor Actor) []BulkResult {
	out := make([]BulkResult, len(ids))
	for i, id := range ids {
		out[i] = BulkResult{DocumentID: id, Err: s.ReviewDocument(ctx, id, decision, reason, actor)}
	}
	return out
}

// sendBack returns the driver's open application for corrections.
func (s *Service) sendBack(ctx context.Context, q *store.Queries, driverID uuid.UUID, now time.Time) error {
	open, err := q.GetOpenApplication(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("load application: %w", err)
	}
	if err := q.SetApplicationStatus(ctx, store.SetApplicationStatusParams{Status: statusResubmit, Now: now, ID: open.ID}); err != nil {
		return fmt.Errorf("return application: %w", err)
	}
	return nil
}

// ReviewApplication makes the final decision. Approval is refused unless every
// required document is validated and in date, whoever is asking.
func (s *Service) ReviewApplication(ctx context.Context, applicationID uuid.UUID, decision string, rawReason *string, actor Actor) error {
	type outcome struct{ application, driver string }
	result, ok := map[string]outcome{
		decisionApprove:  {statusApproved, statusApproved},
		decisionReject:   {statusRejected, statusRejected},
		decisionResubmit: {statusResubmit, statusPending},
		decisionSuspend:  {statusSuspended, statusSuspended},
	}[decision]
	if !ok {
		return ErrInvalidDecision
	}
	reason, err := cleanReason(rawReason, decision != decisionApprove)
	if err != nil {
		return err
	}
	peek, err := s.queries.GetApplication(ctx, applicationID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("load application: %w", err)
	}
	if peek.DriverID == actor.UserID {
		return ErrSelfReview
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, peek.DriverID); err != nil {
			return err
		}
		app, err := q.GetApplication(ctx, applicationID)
		if err != nil {
			return fmt.Errorf("reload application: %w", err)
		}
		if app.Status != statusPending && app.Status != statusUnderReview && app.Status != statusResubmit {
			return ErrApplicationClosed
		}
		if decision == decisionApprove {
			missing, err := q.CountRequirementsNotMet(ctx, store.CountRequirementsNotMetParams{
				DriverID: app.DriverID, Statuses: []string{docValidated}, Today: new(s.today()),
			})
			if err != nil {
				return fmt.Errorf("count missing documents: %w", err)
			}
			if missing > 0 {
				return ErrDocumentsMissing
			}
		}
		err = q.DecideApplication(ctx, store.DecideApplicationParams{Status: result.application, Now: new(now), Reason: reason, ID: applicationID})
		if err != nil {
			return fmt.Errorf("decide application: %w", err)
		}
		err = q.SetDriverVerification(ctx, store.SetDriverVerificationParams{Status: result.driver, Now: now, UserID: app.DriverID})
		if err != nil {
			return fmt.Errorf("update driver: %w", err)
		}
		err = recordReview(ctx, q, reviewEntry{
			applicationID: applicationID, driverID: app.DriverID, reviewerID: new(actor.UserID),
			decision: decision, before: app.Status, after: result.application, reason: reason, at: now,
		})
		if err != nil {
			return err
		}
		return notify(ctx, q, app.DriverID, result.driver)
	})
}

// ExpireDocuments marks lapsed documents and suspends approved drivers who
// relied on them. It is safe to run repeatedly.
func (s *Service) ExpireDocuments(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, workTimeout)
	defer cancel()
	now := s.now()
	today := s.today()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		expired, err := q.ExpireDocuments(ctx, store.ExpireDocumentsParams{Now: now, Today: new(today)})
		if err != nil {
			return fmt.Errorf("expire documents: %w", err)
		}
		seen := map[uuid.UUID]bool{}
		for _, doc := range expired {
			err := recordReview(ctx, q, reviewEntry{
				applicationID: doc.ApplicationID, documentID: new(doc.ID), driverID: doc.DriverID,
				decision: "expired", before: "live", after: docExpired, at: now,
			})
			if err != nil {
				return err
			}
			if seen[doc.DriverID] {
				continue
			}
			seen[doc.DriverID] = true
			if err := s.suspendForExpiry(ctx, q, doc.DriverID, doc.ApplicationID, now); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Service) suspendForExpiry(ctx context.Context, q *store.Queries, driverID, applicationID uuid.UUID, now time.Time) error {
	if err := lockDriver(ctx, q, driverID); err != nil {
		return err
	}
	driver, err := q.GetVerificationDriver(ctx, driverID)
	if err != nil {
		return fmt.Errorf("load driver: %w", err)
	}
	if driver.VerificationStatus != statusApproved {
		return nil
	}
	if err := q.SetDriverVerification(ctx, store.SetDriverVerificationParams{Status: statusSuspended, Now: now, UserID: driverID}); err != nil {
		return fmt.Errorf("suspend driver: %w", err)
	}
	err = recordReview(ctx, q, reviewEntry{
		applicationID: applicationID, driverID: driverID, decision: "suspended_document_expired",
		before: statusApproved, after: statusSuspended, at: now,
	})
	if err != nil {
		return err
	}
	return notify(ctx, q, driverID, statusSuspended)
}
