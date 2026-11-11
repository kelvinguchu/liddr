package verification

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	closedAccountHold = 365 * 24 * time.Hour
	unusedSelfieHold  = 30 * 24 * time.Hour
	purgeBatch        = 100
)

// PurgeDocuments removes the files of accounts closed for over a year, and
// selfies 30 days after they stopped being a driver's photo. Each file leaves storage before its row is marked, so a failure is retried, and
// storage is never called inside a transaction.
func (s *Service) PurgeDocuments(ctx context.Context) error {
	if s.storage == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, workTimeout)
	defer cancel()
	now := s.now()
	rows, err := s.queries.ListDocumentsToPurge(ctx, store.ListDocumentsToPurgeParams{
		ClosedBefore: new(now.Add(-closedAccountHold)), SelfiesBefore: new(now.Add(-unusedSelfieHold)), Batch: purgeBatch,
	})
	if err != nil {
		return fmt.Errorf("list documents to purge: %w", err)
	}
	var errs []error
	for _, row := range rows {
		if err := s.storage.Delete(ctx, row.StorageKey); err != nil && !errors.Is(err, storage.ErrNotFound) {
			errs = append(errs, fmt.Errorf("delete stored document: %w", err))
			continue
		}
		if err := s.queries.MarkDocumentPurged(ctx, store.MarkDocumentPurgedParams{Now: new(now), ID: row.ID}); err != nil {
			errs = append(errs, fmt.Errorf("mark document purged: %w", err))
		}
	}
	return errors.Join(errs...)
}
