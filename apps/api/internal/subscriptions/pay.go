package subscriptions

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	attemptWindow   = time.Hour
	maxAttempts     = 5
	saveAfterSendBy = 5 * time.Second
)

// Payment is one attempt to pay a subscription.
type Payment struct {
	ID          uuid.UUID
	Channel     string
	Status      string
	AmountKES   int32
	Receipt     *string
	RequestedAt time.Time
	PaidAt      *time.Time
}

// Pay prompts the driver's own verified phone to pay this week. The number is
// never taken from the request, or anyone could spam strangers with prompts.
func (s *Service) Pay(ctx context.Context, driverID uuid.UUID) (Payment, error) {
	now := s.now()
	payment := Payment{ID: uuid.New(), Channel: "stk", Status: "initiated", RequestedAt: now}
	var phone, reference string

	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		driver, err := lockPayingDriver(ctx, q, driverID)
		if err != nil {
			return err
		}
		if driver.VerificationStatus != "approved" {
			return ErrNotVerified
		}
		sub, err := ensureWeek(ctx, q, weekSpec{driverID: driverID, categoryID: driver.VehicleCategoryID, amountKES: driver.WeeklySubscriptionKes, start: weekStart(now), at: now})
		if err != nil {
			return err
		}
		if sub.Status == "active" {
			return ErrAlreadyActive
		}
		recent, err := q.CountRecentPayments(ctx, store.CountRecentPaymentsParams{DriverID: driverID, Since: now.Add(-attemptWindow)})
		if err != nil {
			return fmt.Errorf("count recent payments: %w", err)
		}
		if recent >= maxAttempts {
			return ErrRateLimited
		}

		inserted, err := q.InsertSTKPayment(ctx, store.InsertSTKPaymentParams{
			ID: payment.ID, SubscriptionID: sub.ID, DriverID: driverID, AmountKes: sub.AmountKes, Phone: new(driver.Phone), RequestedAt: now,
		})
		if err != nil {
			return fmt.Errorf("insert payment: %w", err)
		}
		if inserted == 0 {
			return ErrPaymentPending
		}
		payment.AmountKES, phone, reference = sub.AmountKes, driver.Phone, sub.Reference
		return nil
	})
	if err != nil {
		return Payment{}, err
	}

	// Sent after commit: a slow provider must never hold a transaction open.
	response, err := s.gateway.InitiateSTK(ctx, payments.STKRequest{
		AmountKES:        payment.AmountKES,
		Phone:            phone,
		CallbackURL:      s.callbackURL("/stk"),
		AccountReference: reference,
		Description:      "Liddr subscription",
	})
	// The prompt may be on the driver's phone by now, so these writes must not
	// be abandoned just because the driver's connection dropped.
	saveCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), saveAfterSendBy)
	defer cancel()

	switch {
	case err == nil:
		payment.Status = "pending_callback"
		err := s.queries.MarkPaymentPendingCallback(saveCtx, store.MarkPaymentPendingCallbackParams{
			MerchantRequestID: new(response.MerchantRequestID), CheckoutRequestID: new(response.CheckoutRequestID), ID: payment.ID,
		})
		if err != nil {
			return Payment{}, fmt.Errorf("save checkout id: %w", err)
		}
		return payment, nil
	case errors.Is(err, payments.ErrRejected):
		saveErr := s.queries.MarkPaymentRejected(saveCtx, store.MarkPaymentRejectedParams{ResultDesc: new("Rejected by M-Pesa"), ID: payment.ID})
		return Payment{}, errors.Join(ErrPaymentRefused, err, saveErr)
	default:
		// The outcome is unknown and the driver may yet be charged. Keeping the
		// attempt open stops a retry from charging twice until it is resolved.
		s.logger.LogAttrs(ctx, slog.LevelWarn, "stk push outcome unknown", slog.String("payment_id", payment.ID.String()), slog.Any("error", err))
		return payment, nil
	}
}

// History returns the driver's recent payments.
func (s *Service) History(ctx context.Context, driverID uuid.UUID) ([]Payment, error) {
	rows, err := s.queries.ListDriverPayments(ctx, driverID)
	if err != nil {
		return nil, fmt.Errorf("list payments: %w", err)
	}
	out := make([]Payment, len(rows))
	for i, row := range rows {
		out[i] = Payment{ID: row.ID, Channel: row.Channel, Status: row.Status, AmountKES: row.AmountKes, Receipt: row.Receipt, RequestedAt: row.RequestedAt, PaidAt: row.PaidAt}
	}
	return out, nil
}
