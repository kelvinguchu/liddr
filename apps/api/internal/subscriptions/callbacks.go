package subscriptions

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

type outcome struct {
	code    int32
	desc    string
	receipt *string
	// evidence is set when Daraja reported what was paid, which a status query
	// does not do. Absent values inside it are not treated as a mismatch.
	evidence *paymentEvidence
}

type paymentEvidence struct {
	amountKES *int32
	phone     string
}

type paymentRow struct {
	id             uuid.UUID
	subscriptionID uuid.UUID
	driverID       uuid.UUID
	status         string
	amountKES      int32
	phone          *string
}

func isOpen(status string) bool {
	return status == "initiated" || status == "pending_callback"
}

// HandleSTK applies an STK callback. Replays are harmless: the locked payment's
// state decides what can still change. It is deliberately not deduplicated by
// checkout ID, because a later success for that ID has to be able to land.
func (s *Service) HandleSTK(ctx context.Context, body []byte) error {
	callback, err := payments.ParseSTKCallback(body)
	if err != nil {
		return err
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetPaymentByCheckoutForUpdate(ctx, new(callback.CheckoutRequestID))
		if errors.Is(err, pgx.ErrNoRows) {
			return recordUnmatched(ctx, q, "stk", callback.CheckoutRequestID, callback.AmountKES, nil, "unknown_checkout", now)
		}
		if err != nil {
			return fmt.Errorf("load payment: %w", err)
		}
		return applyOutcome(ctx, q, paymentRow{row.ID, row.SubscriptionID, row.DriverID, row.Status, row.AmountKes, row.Phone}, outcome{
			code:     callback.ResultCode,
			desc:     callback.ResultDesc,
			receipt:  optional(callback.Receipt),
			evidence: &paymentEvidence{amountKES: callback.AmountKES, phone: callback.Phone},
		}, now)
	})
}

func optional(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func recordUnmatched(ctx context.Context, q *store.Queries, kind, ref string, amount *int32, account *string, reason string, now time.Time) error {
	err := q.InsertUnmatchedCallback(ctx, store.InsertUnmatchedCallbackParams{
		Kind: kind, ExternalRef: ref, AmountKes: amount, AccountReference: account, Reason: reason, ReceivedAt: now,
	})
	if err != nil {
		return fmt.Errorf("record unmatched callback: %w", err)
	}
	return nil
}

// applyOutcome moves a locked payment. A confirmed success overrides timeout,
// failure or cancellation, and a later failure never overrides a success.
func applyOutcome(ctx context.Context, q *store.Queries, payment paymentRow, result outcome, now time.Time) error {
	if payment.status == "success" || payment.status == "needs_review" {
		return nil
	}
	status := payments.StatusFromResult(result.code)
	params := store.SetPaymentResultParams{Status: status, ResultCode: new(result.code), ResultDesc: new(result.desc), Receipt: result.receipt, ID: payment.id}

	if status != "success" {
		if !isOpen(payment.status) {
			return nil
		}
		return setResult(ctx, q, params)
	}

	if result.evidence != nil && !evidenceMatches(payment, *result.evidence) {
		params.Status = "needs_review"
		if err := setResult(ctx, q, params); err != nil {
			return err
		}
		return auditSystem(ctx, q, "subscription.payment_needs_review", payment.driverID, now)
	}
	params.PaidAt = new(now)
	if err := setResult(ctx, q, params); err != nil {
		return err
	}
	return activate(ctx, q, payment.id, payment.driverID, payment.subscriptionID, now)
}

func evidenceMatches(payment paymentRow, evidence paymentEvidence) bool {
	if evidence.amountKES == nil || *evidence.amountKES != payment.amountKES {
		return false
	}
	return evidence.phone == "" || payment.phone == nil || evidence.phone == *payment.phone
}

func setResult(ctx context.Context, q *store.Queries, params store.SetPaymentResultParams) error {
	if err := q.SetPaymentResult(ctx, params); err != nil {
		return fmt.Errorf("set payment result: %w", err)
	}
	return nil
}

func auditSystem(ctx context.Context, q *store.Queries, action string, driverID uuid.UUID, now time.Time) error {
	if err := q.InsertSystemAuditEvent(ctx, store.InsertSystemAuditEventParams{Action: action, UserID: new(driverID), CreatedAt: now}); err != nil {
		return fmt.Errorf("record audit event: %w", err)
	}
	return nil
}

// activate credits a paid payment to a week. A payment for a past week counts
// for the current week and never reactivates the old one. A week already paid
// pushes the credit to the next week, so a second payment is not lost.
func activate(ctx context.Context, q *store.Queries, paymentID, driverID, subscriptionID uuid.UUID, now time.Time) error {
	if err := q.LockDriverRow(ctx, driverID); err != nil {
		return fmt.Errorf("lock driver: %w", err)
	}
	paid, err := q.GetSubscriptionByIDForUpdate(ctx, subscriptionID)
	if err != nil {
		return fmt.Errorf("load subscription: %w", err)
	}

	spec := weekSpec{driverID: driverID, categoryID: paid.VehicleCategoryID, amountKES: paid.AmountKes, at: now}
	target := paid
	if current := weekStart(now); paid.WeekEnd.Before(current) {
		spec.start = current
		if target, err = ensureWeek(ctx, q, spec); err != nil {
			return err
		}
	}
	for target.Status == "active" {
		spec.start = target.WeekStart.AddDate(0, 0, 7)
		if target, err = ensureWeek(ctx, q, spec); err != nil {
			return err
		}
	}

	if target.ID != paid.ID {
		if err := q.MovePaymentToSubscription(ctx, store.MovePaymentToSubscriptionParams{SubscriptionID: target.ID, ID: paymentID}); err != nil {
			return fmt.Errorf("move payment: %w", err)
		}
	}
	if err := q.ActivateSubscription(ctx, store.ActivateSubscriptionParams{Now: new(now), ID: target.ID}); err != nil {
		return fmt.Errorf("activate subscription: %w", err)
	}
	if err := q.SetDriverSubscriptionActive(ctx, driverID); err != nil {
		return fmt.Errorf("activate driver: %w", err)
	}
	return auditSystem(ctx, q, "subscription.activated", driverID, now)
}

// HandleC2B applies a paybill confirmation. Money that cannot be applied is
// recorded for operations instead of being refused, because it has been paid.
func (s *Service) HandleC2B(ctx context.Context, body []byte) error {
	callback, err := payments.ParseC2BCallback(body)
	if err != nil {
		return err
	}
	now := s.now()
	account := optional(callback.AccountReference)
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		sub, err := q.GetSubscriptionByReference(ctx, callback.AccountReference)
		if errors.Is(err, pgx.ErrNoRows) {
			return recordUnmatched(ctx, q, "c2b", callback.TransactionID, callback.AmountKES, account, "unknown_reference", now)
		}
		if err != nil {
			return fmt.Errorf("load subscription: %w", err)
		}
		if callback.AmountKES == nil || *callback.AmountKES != sub.AmountKes {
			return recordUnmatched(ctx, q, "c2b", callback.TransactionID, callback.AmountKES, account, "amount_mismatch", now)
		}

		id := uuid.New()
		inserted, err := q.InsertC2BPayment(ctx, store.InsertC2BPaymentParams{
			ID: id, SubscriptionID: sub.ID, DriverID: sub.DriverID, AmountKes: sub.AmountKes, Phone: optional(callback.Phone), Receipt: new(callback.TransactionID), Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert payment: %w", err)
		}
		if inserted == 0 {
			return nil
		}
		return activate(ctx, q, id, sub.DriverID, sub.ID, now)
	})
}
