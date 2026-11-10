package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net/http"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

func errorBody(ctx context.Context, code, message string) Error {
	return Error{Code: code, Message: message, RequestId: requestID(ctx)}
}

func requestMeta(ctx context.Context) auth.RequestMeta {
	info := requestInfoFrom(ctx)
	return auth.RequestMeta{IP: info.ip, RequestID: info.id}
}

func toSession(t auth.Tokens) Session {
	return Session{
		AccessToken:           t.AccessToken,
		AccessTokenExpiresIn:  int32(t.AccessTTL.Seconds()),
		RefreshToken:          t.RefreshToken,
		RefreshTokenExpiresIn: int32(t.RefreshTTL.Seconds()),
		UserId:                t.UserID,
		Roles:                 toRoles(t.Roles),
	}
}

func toRoles(roles []auth.Role) []Role {
	out := make([]Role, len(roles))
	for i, role := range roles {
		out[i] = Role(role)
	}
	return out
}

func isAccountBlocked(err error) bool {
	return errors.Is(err, auth.ErrAccountSuspended) ||
		errors.Is(err, auth.ErrAccountBanned) ||
		errors.Is(err, auth.ErrAccountDeactivated)
}

// RequestOtp sends a sign-in code.
func (a *API) RequestOtp(ctx context.Context, req RequestOtpRequestObject) (RequestOtpResponseObject, error) {
	challenge, err := a.deps.Auth.RequestOTP(ctx, auth.OTPRequest{
		Phone: req.Body.Phone,
		Role:  auth.Role(req.Body.Role),
		Meta:  requestMeta(ctx),
	})
	if limited, ok := errors.AsType[*auth.RateLimitError](err); ok {
		return RequestOtp429JSONResponse{
			Body:    errorBody(ctx, "RATE_LIMITED", "Too many codes requested. Please wait and try again."),
			Headers: RequestOtp429ResponseHeaders{RetryAfter: limited.RetryAfterSeconds()},
		}, nil
	}
	switch {
	case err == nil:
		return RequestOtp201JSONResponse{ChallengeId: challenge.ID, ExpiresAt: challenge.ExpiresAt}, nil
	case errors.Is(err, auth.ErrInvalidPhone):
		return RequestOtp400JSONResponse(errorBody(ctx, "INVALID_PHONE", "Enter a Kenyan mobile number, such as 0712345678.")), nil
	case errors.Is(err, auth.ErrInvalidRole):
		return RequestOtp400JSONResponse(errorBody(ctx, "INVALID_ROLE", "Choose a valid account type.")), nil
	case errors.Is(err, auth.ErrDeliveryUnavailable):
		a.deps.Logger.LogAttrs(ctx, slog.LevelError, "sign-in code delivery failed",
			slog.String("request_id", requestID(ctx)), slog.Any("error", err))
		return RequestOtp503JSONResponse(errorBody(ctx, "SMS_UNAVAILABLE", "We could not send your code. Please try again shortly.")), nil
	default:
		return nil, err
	}
}

// VerifyOtp exchanges a sign-in code for a session.
func (a *API) VerifyOtp(ctx context.Context, req VerifyOtpRequestObject) (VerifyOtpResponseObject, error) {
	tokens, err := a.deps.Auth.VerifyOTP(ctx, req.Body.ChallengeId, req.Body.Code, requestMeta(ctx))
	if err == nil {
		return VerifyOtp200JSONResponse(toSession(tokens)), nil
	}
	status, code, message, ok := otpProblem(err)
	if !ok {
		return nil, err
	}
	body := errorBody(ctx, code, message)
	switch status {
	case http.StatusBadRequest:
		return VerifyOtp400JSONResponse(body), nil
	case http.StatusTooManyRequests:
		return VerifyOtp429JSONResponse(body), nil
	default:
		return VerifyOtp403JSONResponse(body), nil
	}
}

// otpProblem maps a refused sign-in code to its answer. ok is false for an
// unexpected error, which the caller reports as a failure.
func otpProblem(err error) (status int, code, message string, ok bool) {
	switch {
	case errors.Is(err, auth.ErrInvalidCode):
		return http.StatusBadRequest, "INVALID_CODE", "That code is incorrect.", true
	case errors.Is(err, auth.ErrCodeExpired):
		return http.StatusBadRequest, "CODE_EXPIRED", "That code has expired. Request a new one.", true
	case errors.Is(err, auth.ErrTooManyAttempts):
		return http.StatusTooManyRequests, "TOO_MANY_ATTEMPTS", "Too many incorrect codes. Request a new one.", true
	case errors.Is(err, auth.ErrNotStaff):
		return http.StatusForbidden, "NOT_STAFF", "This number does not have staff access.", true
	case isAccountBlocked(err):
		code, message := accountBlocked(err)
		return http.StatusForbidden, code, message, true
	default:
		return 0, "", "", false
	}
}

// RefreshSession rotates a refresh token.
func (a *API) RefreshSession(ctx context.Context, req RefreshSessionRequestObject) (RefreshSessionResponseObject, error) {
	tokens, err := a.deps.Auth.Refresh(ctx, req.Body.RefreshToken, requestMeta(ctx))
	switch {
	case err == nil:
		return RefreshSession200JSONResponse(toSession(tokens)), nil
	case errors.Is(err, auth.ErrInvalidToken):
		return RefreshSession401JSONResponse(errorBody(ctx, "UNAUTHORIZED", "Please sign in again.")), nil
	case isAccountBlocked(err):
		code, message := accountBlocked(err)
		return RefreshSession403JSONResponse(errorBody(ctx, code, message)), nil
	default:
		return nil, err
	}
}

// Logout ends the device's session.
func (a *API) Logout(ctx context.Context, req LogoutRequestObject) (LogoutResponseObject, error) {
	if err := a.deps.Auth.Logout(ctx, req.Body.RefreshToken, requestMeta(ctx)); err != nil {
		return nil, err
	}
	return Logout204Response{}, nil
}

// GetMe returns the signed-in account.
func (a *API) GetMe(ctx context.Context, _ GetMeRequestObject) (GetMeResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	name, err := a.deps.Auth.DisplayName(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	return GetMe200JSONResponse{Id: p.UserID, Phone: p.Phone, Roles: toRoles(p.Roles), DisplayName: name}, nil
}
