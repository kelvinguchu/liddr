package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"

	"github.com/oapi-codegen/runtime/types"

	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
)

func toAPIPayment(p subscriptions.Payment) SubscriptionPayment {
	return SubscriptionPayment{
		Id:          p.ID,
		Channel:     SubscriptionPaymentChannel(p.Channel),
		Status:      SubscriptionPaymentStatus(p.Status),
		AmountKes:   p.AmountKES,
		Receipt:     p.Receipt,
		RequestedAt: p.RequestedAt,
		PaidAt:      p.PaidAt,
	}
}

// GetSubscription returns this week's subscription.
func (a *API) GetSubscription(ctx context.Context, _ GetSubscriptionRequestObject) (GetSubscriptionResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	summary, err := a.deps.Subscriptions.Current(ctx, driver)
	if err != nil {
		return nil, err
	}
	return GetSubscription200JSONResponse{
		Status:           SubscriptionStatus(summary.Status),
		AmountKes:        summary.AmountKES,
		WeekStart:        types.Date{Time: summary.WeekStart},
		WeekEnd:          types.Date{Time: summary.WeekEnd},
		Reference:        summary.Reference,
		PaybillShortcode: summary.Shortcode,
	}, nil
}

// ListSubscriptionPayments returns recent payments.
func (a *API) ListSubscriptionPayments(ctx context.Context, _ ListSubscriptionPaymentsRequestObject) (ListSubscriptionPaymentsResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	history, err := a.deps.Subscriptions.History(ctx, driver)
	if err != nil {
		return nil, err
	}
	data := make([]SubscriptionPayment, len(history))
	for i, payment := range history {
		data[i] = toAPIPayment(payment)
	}
	return ListSubscriptionPayments200JSONResponse{Data: data}, nil
}

// PaySubscription sends an M-Pesa prompt.
func (a *API) PaySubscription(ctx context.Context, _ PaySubscriptionRequestObject) (PaySubscriptionResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	payment, err := a.deps.Subscriptions.Pay(ctx, driver)
	if err != nil {
		return nil, err
	}
	return PaySubscription202JSONResponse(toAPIPayment(payment)), nil
}

var accepted = MpesaAck{ResultCode: 0, ResultDesc: "Accepted"}

// callbackBody authorizes a Daraja callback and returns its body for parsing.
func (a *API) callbackBody(ctx context.Context, token string, body *MpesaCallback) ([]byte, error) {
	allowed := a.deps.MpesaAllowedIPs
	if len(allowed) > 0 && !slices.Contains(allowed, requestInfoFrom(ctx).ip) {
		return nil, subscriptions.ErrCallbackRefused
	}
	if !a.deps.Subscriptions.VerifyCallbackToken(token) {
		return nil, subscriptions.ErrCallbackRefused
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("encode callback: %w", err)
	}
	return encoded, nil
}

// MpesaStkCallback receives an STK result.
func (a *API) MpesaStkCallback(ctx context.Context, req MpesaStkCallbackRequestObject) (MpesaStkCallbackResponseObject, error) {
	body, err := a.callbackBody(ctx, req.Token, req.Body)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Subscriptions.HandleSTK(ctx, body); err != nil {
		return nil, err
	}
	return MpesaStkCallback200JSONResponse(accepted), nil
}

// MpesaC2bValidation accepts every paybill payment. Refusing one here would
// bounce a driver's money over a typing mistake that operations can fix.
func (a *API) MpesaC2bValidation(ctx context.Context, req MpesaC2bValidationRequestObject) (MpesaC2bValidationResponseObject, error) {
	if _, err := a.callbackBody(ctx, req.Token, req.Body); err != nil {
		return nil, err
	}
	return MpesaC2bValidation200JSONResponse(accepted), nil
}

// MpesaC2bConfirmation receives a paybill payment.
func (a *API) MpesaC2bConfirmation(ctx context.Context, req MpesaC2bConfirmationRequestObject) (MpesaC2bConfirmationResponseObject, error) {
	body, err := a.callbackBody(ctx, req.Token, req.Body)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Subscriptions.HandleC2B(ctx, body); err != nil {
		return nil, err
	}
	return MpesaC2bConfirmation200JSONResponse(accepted), nil
}
