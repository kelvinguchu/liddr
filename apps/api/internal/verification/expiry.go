package verification

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

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
