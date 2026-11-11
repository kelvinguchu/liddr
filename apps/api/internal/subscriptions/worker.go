package subscriptions

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	workerInterval   = 30 * time.Second
	reconcileAfter   = 90 * time.Second
	recheckAfter     = time.Minute
	reconcileBatch   = 50
	givenUpAfter     = 30 * time.Minute
	unknownOutcomeBy = 5 * time.Minute
	graceAfterWeek   = 6 * time.Hour
)

// Run reconciles payments and expires subscriptions until ctx ends.
func (s *Service) Run(ctx context.Context, logger *slog.Logger) {
	ticker := time.NewTicker(workerInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := errors.Join(s.Reconcile(ctx), s.ExpireLapsed(ctx), s.RemindRenewals(ctx)); err != nil && !errors.Is(err, context.Canceled) {
				logger.LogAttrs(ctx, slog.LevelError, "subscription cycle failed", slog.Any("error", err))
			}
		}
	}
}

// Reconcile asks Daraja about payments whose callback never came. Rows are
// claimed in one short statement so the provider is called outside any
// transaction, and instances running together do not check the same payment.
func (s *Service) Reconcile(ctx context.Context) error {
	now := s.now()
	claimed, err := s.queries.ClaimPaymentsToReconcile(ctx, store.ClaimPaymentsToReconcileParams{
		Now:             new(now),
		RequestedBefore: now.Add(-reconcileAfter),
		CheckedBefore:   new(now.Add(-recheckAfter)),
		Batch:           reconcileBatch,
	})
	if err != nil {
		return fmt.Errorf("claim payments: %w", err)
	}
	var errs []error
	for _, row := range claimed {
		errs = append(errs, s.reconcileOne(ctx, row, now))
	}
	return errors.Join(errs...)
}

func (s *Service) reconcileOne(ctx context.Context, row store.ClaimPaymentsToReconcileRow, now time.Time) error {
	age := now.Sub(row.RequestedAt)
	if row.CheckoutRequestID == nil {
		// The push failed in an unknown way and left nothing to query with.
		if age < unknownOutcomeBy {
			return nil
		}
		return s.applyQueried(ctx, row.ID, outcome{code: payments.ResultTimeout, desc: "No confirmation from M-Pesa"}, now)
	}

	result, err := s.gateway.QuerySTK(ctx, *row.CheckoutRequestID)
	if err != nil || result.Pending {
		if age < givenUpAfter {
			return err
		}
		return s.applyQueried(ctx, row.ID, outcome{code: payments.ResultTimeout, desc: "No confirmation from M-Pesa"}, now)
	}
	return s.applyQueried(ctx, row.ID, outcome{code: result.ResultCode, desc: result.ResultDesc}, now)
}

func (s *Service) applyQueried(ctx context.Context, paymentID uuid.UUID, result outcome, now time.Time) error {
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetPaymentForUpdate(ctx, paymentID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("load payment: %w", err)
		}
		return applyOutcome(ctx, q, paymentRow{row.ID, row.SubscriptionID, row.DriverID, row.Status, row.AmountKes, row.Phone}, result, now)
	})
}

// ExpireLapsed closes finished weeks. Drivers keep working for six hours into
// the new week to catch late payers, and are then taken offline.
func (s *Service) ExpireLapsed(ctx context.Context) error {
	now := s.now()
	today := dateOf(now)
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.ExpireLapsedSubscriptions(ctx, store.ExpireLapsedSubscriptionsParams{Now: new(now), Today: today}); err != nil {
			return fmt.Errorf("expire subscriptions: %w", err)
		}
		// A date is midnight UTC, so subtract three hours to get Nairobi midnight.
		weekOpened := weekStart(now).Add(-3 * time.Hour)
		err := q.DowngradeUnpaidDrivers(ctx, store.DowngradeUnpaidDriversParams{InGrace: now.Before(weekOpened.Add(graceAfterWeek)), Today: today})
		if err != nil {
			return fmt.Errorf("downgrade drivers: %w", err)
		}
		return nil
	})
}
