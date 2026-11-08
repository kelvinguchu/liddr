package auth_test

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

func refresh(t *testing.T, h *harness, token string) auth.Tokens {
	t.Helper()
	tokens, err := h.svc.Refresh(t.Context(), token, testMeta())
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	return tokens
}

func assertValid(t *testing.T, h *harness, accessToken string) {
	t.Helper()
	if _, err := h.svc.Authenticate(t.Context(), accessToken); err != nil {
		t.Errorf("Authenticate = %v, want nil", err)
	}
}

func assertInvalid(t *testing.T, h *harness, accessToken string) {
	t.Helper()
	if _, err := h.svc.Authenticate(t.Context(), accessToken); !errors.Is(err, auth.ErrInvalidToken) {
		t.Errorf("Authenticate = %v, want ErrInvalidToken", err)
	}
}

func assertRefreshRejected(t *testing.T, h *harness, token string) {
	t.Helper()
	if _, err := h.svc.Refresh(t.Context(), token, testMeta()); !errors.Is(err, auth.ErrInvalidToken) {
		t.Errorf("Refresh = %v, want ErrInvalidToken", err)
	}
}

func TestAccessTokenExpires(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleRider)
	h.clock.Advance(15*time.Minute - time.Second)
	assertValid(t, h, tokens.AccessToken)
	h.clock.Advance(time.Second)
	assertInvalid(t, h, tokens.AccessToken)
}

func TestRefreshTokenExpires(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleRider)
	h.clock.Advance(30 * 24 * time.Hour)
	assertRefreshRejected(t, h, tokens.RefreshToken)
}

func TestRotationKillsOldAccessToken(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)
	second := refresh(t, h, first.RefreshToken)
	assertInvalid(t, h, first.AccessToken)
	assertValid(t, h, second.AccessToken)
}

// The legacy backend rolled this revocation back along with the error, so a
// stolen token's family stayed alive after reuse was "detected".
func TestReuseAfterGraceRevokesFamilyDurably(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)
	second := refresh(t, h, first.RefreshToken)

	h.clock.Advance(31 * time.Second)
	assertRefreshRejected(t, h, first.RefreshToken)

	assertInvalid(t, h, second.AccessToken)
	assertRefreshRejected(t, h, second.RefreshToken)
	if got := auditCount(t, h, "auth.session_revoked.reuse_detected"); got != 1 {
		t.Errorf("reuse audit events = %d, want 1", got)
	}
}

func TestRetryWithinGraceReplacesLostTokens(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)
	lost := refresh(t, h, first.RefreshToken)

	h.clock.Advance(5 * time.Second)
	retried := refresh(t, h, first.RefreshToken)

	assertValid(t, h, retried.AccessToken)
	assertInvalid(t, h, lost.AccessToken)
	if got := auditCount(t, h, "auth.session_revoked.reuse_detected"); got != 0 {
		t.Errorf("reuse audit events = %d, want 0 for a retry", got)
	}
}

func TestRetriesCannotExtendGrace(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)
	refresh(t, h, first.RefreshToken)

	h.clock.Advance(20 * time.Second)
	latest := refresh(t, h, first.RefreshToken)

	h.clock.Advance(20 * time.Second)
	assertRefreshRejected(t, h, first.RefreshToken)
	assertInvalid(t, h, latest.AccessToken)
}

func TestSpentTokenAfterNextRotationIsReuse(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)
	second := refresh(t, h, first.RefreshToken)
	third := refresh(t, h, second.RefreshToken)

	assertRefreshRejected(t, h, first.RefreshToken)
	assertInvalid(t, h, third.AccessToken)
}

func TestConcurrentRefreshesLeaveOneLiveSession(t *testing.T) {
	h := newHarness(t)
	first := signIn(t, h, testPhone, auth.RoleRider)

	var wg sync.WaitGroup
	for range 10 {
		wg.Go(func() {
			// Each result is checked through the final session count below.
			_, _ = h.svc.Refresh(t.Context(), first.RefreshToken, testMeta())
		})
	}
	wg.Wait()

	var live int
	err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM auth_sessions WHERE revoked_at IS NULL`).Scan(&live)
	if err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if live != 1 {
		t.Errorf("live sessions = %d, want 1", live)
	}
}

func TestLogout(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleRider)

	if err := h.svc.Logout(t.Context(), tokens.RefreshToken, testMeta()); err != nil {
		t.Fatalf("Logout: %v", err)
	}
	assertInvalid(t, h, tokens.AccessToken)
	assertRefreshRejected(t, h, tokens.RefreshToken)

	for name, token := range map[string]string{"repeat": tokens.RefreshToken, "unknown": "not-a-token"} {
		if err := h.svc.Logout(t.Context(), token, testMeta()); err != nil {
			t.Errorf("%s logout = %v, want nil", name, err)
		}
	}
}

func TestBlockedAccounts(t *testing.T) {
	tests := []struct {
		status string
		want   error
	}{
		{"suspended", auth.ErrAccountSuspended},
		{"banned", auth.ErrAccountBanned},
		{"deactivated", auth.ErrAccountDeactivated},
	}
	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			h := newHarness(t)
			tokens := signIn(t, h, testPhone, auth.RoleRider)
			setAccountStatus(t, h, tokens.UserID, tt.status)

			if _, err := h.svc.Authenticate(t.Context(), tokens.AccessToken); !errors.Is(err, tt.want) {
				t.Errorf("Authenticate = %v, want %v", err, tt.want)
			}
			if _, err := h.svc.Refresh(t.Context(), tokens.RefreshToken, testMeta()); !errors.Is(err, tt.want) {
				t.Errorf("Refresh = %v, want %v", err, tt.want)
			}

			// Lifting the block must not revive the family it revoked.
			setAccountStatus(t, h, tokens.UserID, "active")
			assertInvalid(t, h, tokens.AccessToken)
			assertRefreshRejected(t, h, tokens.RefreshToken)
		})
	}
}

func TestRestrictedAccountCanStillAuthenticate(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleRider)
	setAccountStatus(t, h, tokens.UserID, "restricted")
	assertValid(t, h, tokens.AccessToken)
}
