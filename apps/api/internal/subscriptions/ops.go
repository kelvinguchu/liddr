package subscriptions

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ErrPaymentNotFound reports an unknown checkout reference.
var ErrPaymentNotFound = errors.New("payment not found")

// PaymentDetail is a payment as staff see it. The phone is masked, because
// staff need to recognize a number and not to dial it.
type PaymentDetail struct {
	ID          uuid.UUID
	DriverID    uuid.UUID
	Channel     string
	Status      string
	AmountKES   int32
	PhoneMasked string
	Receipt     *string
	RequestedAt time.Time
	PaidAt      *time.Time
}

func mask(phone *string) string {
	if phone == nil || len(*phone) < 4 {
		return "****"
	}
	return "****" + (*phone)[len(*phone)-4:]
}

// PaymentByCheckout finds a payment by its M-Pesa checkout reference.
func (s *Service) PaymentByCheckout(ctx context.Context, checkoutID string) (PaymentDetail, error) {
	row, err := s.queries.GetPaymentByCheckout(ctx, new(checkoutID))
	if errors.Is(err, pgx.ErrNoRows) {
		return PaymentDetail{}, ErrPaymentNotFound
	}
	if err != nil {
		return PaymentDetail{}, fmt.Errorf("load payment: %w", err)
	}
	return PaymentDetail{
		ID: row.ID, DriverID: row.DriverID, Channel: row.Channel, Status: row.Status, AmountKES: row.AmountKes,
		PhoneMasked: mask(row.Phone), Receipt: row.Receipt, RequestedAt: row.RequestedAt, PaidAt: row.PaidAt,
	}, nil
}

// Recheck asks M-Pesa again about a payment that has not settled. A success
// reported now overrides any earlier failure, as with a late callback.
func (s *Service) Recheck(ctx context.Context, checkoutID string) (PaymentDetail, error) {
	row, err := s.queries.GetPaymentByCheckout(ctx, new(checkoutID))
	if errors.Is(err, pgx.ErrNoRows) {
		return PaymentDetail{}, ErrPaymentNotFound
	}
	if err != nil {
		return PaymentDetail{}, fmt.Errorf("load payment: %w", err)
	}
	result, err := s.gateway.QuerySTK(ctx, checkoutID)
	if err != nil {
		return PaymentDetail{}, fmt.Errorf("query m-pesa: %w", err)
	}
	if !result.Pending {
		if err := s.applyQueried(ctx, row.ID, outcome{code: result.ResultCode, desc: result.ResultDesc}, s.now()); err != nil {
			return PaymentDetail{}, err
		}
	}
	return s.PaymentByCheckout(ctx, checkoutID)
}
