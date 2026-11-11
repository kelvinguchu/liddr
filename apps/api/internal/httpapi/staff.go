package httpapi

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

const (
	scopePrefixMFA = "mfa:"
	scopeMFAExempt = "mfa:exempt"
	scopeStepUp    = "mfa:step-up"
	headerStepUp   = "X-Step-Up-Token"
)

var (
	errMFAEnrolmentRequired = errors.New("authenticator enrolment required")
	errAddressNotAllowed    = errors.New("address not allowed for staff routes")
)

// splitScopes separates a route's roles from its two-factor requirement.
func splitScopes(scopes []string) (roles, requirement []string) {
	for _, scope := range scopes {
		if strings.HasPrefix(scope, scopePrefixMFA) {
			requirement = append(requirement, scope)
			continue
		}
		roles = append(roles, scope)
	}
	return roles, requirement
}

// viaStaffRoleOnly reports whether the caller got past the role check only by
// being staff. A rider reaching a route open to riders owes no second factor.
func viaStaffRoleOnly(held []auth.Role, allowed []string) bool {
	if len(allowed) == 0 {
		return false
	}
	return !slices.ContainsFunc(held, func(role auth.Role) bool {
		return role != auth.RoleOps && role != auth.RoleAdmin && slices.Contains(allowed, string(role))
	})
}

// checkStaffAccess applies network and two-factor rules. Enrolment is required
// unless the contract explicitly exempts a route, so a new staff route is
// protected even if its author forgets. stepUp is the step-up proof sent with
// the request, from its header or the console's cookie.
func (a *API) checkStaffAccess(r *http.Request, p auth.Principal, roles, requirement []string, stepUp string) error {
	if viaStaffRoleOnly(p.Roles, roles) {
		if !a.staffAddressAllowed(r) {
			return errAddressNotAllowed
		}
		if !p.MFAEnrolled && !slices.Contains(requirement, scopeMFAExempt) {
			return errMFAEnrolmentRequired
		}
	}
	if slices.Contains(requirement, scopeStepUp) {
		return a.deps.Auth.CheckStepUp(p, stepUp)
	}
	return nil
}

func (a *API) staffAddressAllowed(r *http.Request) bool {
	if len(a.deps.OpsAllowedNets) == 0 {
		return true
	}
	address := clientAddress(r, a.deps.TrustedProxyHops)
	for _, network := range a.deps.OpsAllowedNets {
		if network.Contains(address) {
			return true
		}
	}
	return false
}

// BeginTotpSetup starts enrolling an authenticator.
func (a *API) BeginTotpSetup(ctx context.Context, req BeginTotpSetupRequestObject) (BeginTotpSetupResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	token := ""
	if req.Params.XStepUpToken != nil {
		token = *req.Params.XStepUpToken
	}
	setup, err := a.deps.Auth.BeginTOTPSetup(ctx, p, token, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return BeginTotpSetup201JSONResponse{Secret: setup.Secret, OtpauthUri: setup.URI, ExpiresAt: setup.ExpiresAt}, nil
}

// ConfirmTotpSetup activates an authenticator.
func (a *API) ConfirmTotpSetup(ctx context.Context, req ConfirmTotpSetupRequestObject) (ConfirmTotpSetupResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Auth.ConfirmTOTPSetup(ctx, p, req.Body.Code, requestMeta(ctx)); err != nil {
		return nil, err
	}
	return ConfirmTotpSetup204Response{}, nil
}

// VerifyStepUp exchanges a code for a step-up token.
func (a *API) VerifyStepUp(ctx context.Context, req VerifyStepUpRequestObject) (VerifyStepUpResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	grant, err := a.deps.Auth.VerifyStepUp(ctx, p, req.Body.Code, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return VerifyStepUp200JSONResponse{StepUpToken: grant.Token, ExpiresIn: int32(grant.ExpiresIn.Seconds())}, nil
}
