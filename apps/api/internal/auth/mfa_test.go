package auth_test

import (
	"errors"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

// staffPrincipal signs in and returns the principal for that session.
func staffPrincipal(t *testing.T, h *harness) auth.Principal {
	t.Helper()
	tokens := signIn(t, h, testPhone, auth.RoleRider)
	p, err := h.svc.Authenticate(t.Context(), tokens.AccessToken)
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	return p
}

func TestFirstEnrolmentNeedsARecentSignIn(t *testing.T) {
	h := newHarness(t)
	p := staffPrincipal(t, h)
	h.clock.Advance(16 * time.Minute)
	if _, err := h.svc.BeginTOTPSetup(t.Context(), p, "", testMeta()); !errors.Is(err, auth.ErrFreshSignInRequired) {
		t.Errorf("BeginTOTPSetup on an old session = %v", err)
	}
}

func enrolled(t *testing.T, h *harness) (auth.Principal, string) {
	t.Helper()
	p := staffPrincipal(t, h)
	setup, err := h.svc.BeginTOTPSetup(t.Context(), p, "", testMeta())
	if err != nil {
		t.Fatalf("BeginTOTPSetup: %v", err)
	}
	code, err := auth.TOTPCode(setup.Secret, h.clock.Now())
	if err != nil {
		t.Fatalf("TOTPCode: %v", err)
	}
	if err := h.svc.ConfirmTOTPSetup(t.Context(), p, code, testMeta()); err != nil {
		t.Fatalf("ConfirmTOTPSetup: %v", err)
	}
	return p, setup.Secret
}

func TestEnrolmentSetupExpires(t *testing.T) {
	h := newHarness(t)
	p := staffPrincipal(t, h)
	setup, err := h.svc.BeginTOTPSetup(t.Context(), p, "", testMeta())
	if err != nil {
		t.Fatalf("BeginTOTPSetup: %v", err)
	}
	h.clock.Advance(11 * time.Minute)
	code, err := auth.TOTPCode(setup.Secret, h.clock.Now())
	if err != nil {
		t.Fatalf("TOTPCode: %v", err)
	}
	if err := h.svc.ConfirmTOTPSetup(t.Context(), p, code, testMeta()); !errors.Is(err, auth.ErrTOTPNoEnrolment) {
		t.Errorf("ConfirmTOTPSetup after expiry = %v", err)
	}
}

func TestStepUpTokenIsBoundAndShortLived(t *testing.T) {
	h := newHarness(t)
	p, secret := enrolled(t, h)
	h.clock.Advance(30 * time.Second)
	code, err := auth.TOTPCode(secret, h.clock.Now())
	if err != nil {
		t.Fatalf("TOTPCode: %v", err)
	}
	grant, err := h.svc.VerifyStepUp(t.Context(), p, code, testMeta())
	if err != nil {
		t.Fatalf("VerifyStepUp: %v", err)
	}
	if err := h.svc.CheckStepUp(p, grant.Token); err != nil {
		t.Errorf("CheckStepUp on a fresh token = %v", err)
	}

	otherSession := p
	otherSession.SessionID[0] ^= 1
	cases := []struct {
		name  string
		p     auth.Principal
		token string
	}{
		{"empty", p, ""},
		{"not base64", p, "!!!"},
		{"tampered", p, grant.Token[:len(grant.Token)-2] + "AA"},
		{"another session", otherSession, grant.Token},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := h.svc.CheckStepUp(tc.p, tc.token); !errors.Is(err, auth.ErrStepUpRequired) {
				t.Errorf("CheckStepUp = %v", err)
			}
		})
	}

	h.clock.Advance(5 * time.Minute)
	if err := h.svc.CheckStepUp(p, grant.Token); !errors.Is(err, auth.ErrStepUpRequired) {
		t.Errorf("CheckStepUp after five minutes = %v", err)
	}
}

func TestStaffRoleCannotBeGrantedToOrdinaryRoles(t *testing.T) {
	h := newHarness(t)
	if err := h.svc.GrantRole(t.Context(), testPhone, auth.RoleRider); !errors.Is(err, auth.ErrInvalidRole) {
		t.Errorf("GrantRole(rider) = %v", err)
	}
}
