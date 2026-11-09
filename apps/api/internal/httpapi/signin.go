package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
)

// RequestEmailOtp sends a sign-in code by email.
func (a *API) RequestEmailOtp(ctx context.Context, req RequestEmailOtpRequestObject) (RequestEmailOtpResponseObject, error) {
	challenge, err := a.deps.Auth.RequestEmailOTP(ctx, req.Body.Email, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return RequestEmailOtp201JSONResponse{ChallengeId: challenge.ID, ExpiresAt: challenge.ExpiresAt}, nil
}

// VerifyEmailOtp exchanges an email code for a session.
func (a *API) VerifyEmailOtp(ctx context.Context, req VerifyEmailOtpRequestObject) (VerifyEmailOtpResponseObject, error) {
	tokens, err := a.deps.Auth.VerifyEmailOTP(ctx, req.Body.ChallengeId, req.Body.Code, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return VerifyEmailOtp200JSONResponse(toSession(tokens)), nil
}

// SignInWithGoogle exchanges a Google ID token for a session.
func (a *API) SignInWithGoogle(ctx context.Context, req SignInWithGoogleRequestObject) (SignInWithGoogleResponseObject, error) {
	tokens, err := a.deps.Auth.SignInWithGoogle(ctx, req.Body.IdToken, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return SignInWithGoogle200JSONResponse(toSession(tokens)), nil
}

func toPaymentDetail(p subscriptions.PaymentDetail) PaymentDetail {
	return PaymentDetail{Id: p.ID, DriverId: p.DriverID, Channel: p.Channel, Status: p.Status, AmountKes: p.AmountKES, PhoneMasked: p.PhoneMasked, Receipt: p.Receipt, RequestedAt: p.RequestedAt, PaidAt: p.PaidAt}
}

// GetDriverSubscriptionForOps shows a driver's week and payments.
func (a *API) GetDriverSubscriptionForOps(ctx context.Context, req GetDriverSubscriptionForOpsRequestObject) (GetDriverSubscriptionForOpsResponseObject, error) {
	summary, err := a.deps.Subscriptions.Current(ctx, req.UserId)
	if err != nil {
		return nil, err
	}
	history, err := a.deps.Subscriptions.History(ctx, req.UserId)
	if err != nil {
		return nil, err
	}
	data := make([]SubscriptionPayment, len(history))
	for i, payment := range history {
		data[i] = toAPIPayment(payment)
	}
	return GetDriverSubscriptionForOps200JSONResponse{Status: summary.Status, AmountKes: summary.AmountKES, Reference: summary.Reference, Payments: data}, nil
}

// GetPaymentForOps finds a payment by reference.
func (a *API) GetPaymentForOps(ctx context.Context, req GetPaymentForOpsRequestObject) (GetPaymentForOpsResponseObject, error) {
	payment, err := a.deps.Subscriptions.PaymentByCheckout(ctx, req.CheckoutRequestId)
	if err != nil {
		return nil, err
	}
	return GetPaymentForOps200JSONResponse(toPaymentDetail(payment)), nil
}

// RecheckPayment asks M-Pesa again.
func (a *API) RecheckPayment(ctx context.Context, req RecheckPaymentRequestObject) (RecheckPaymentResponseObject, error) {
	payment, err := a.deps.Subscriptions.Recheck(ctx, req.CheckoutRequestId)
	if err != nil {
		return nil, err
	}
	return RecheckPayment200JSONResponse(toPaymentDetail(payment)), nil
}
