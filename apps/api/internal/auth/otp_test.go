package auth_test

import (
	"errors"
	"fmt"
	"net/netip"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

func TestSignInCreatesAccountWithRequestedRole(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, "0712345678", auth.RoleDriver)

	principal, err := h.svc.Authenticate(t.Context(), tokens.AccessToken)
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	if principal.Phone != testPhone {
		t.Errorf("phone = %q, want %q", principal.Phone, testPhone)
	}
	if diff := cmp.Diff(principal.Roles, []auth.Role{auth.RoleDriver}); diff != "" {
		t.Errorf("roles mismatch (-got +want):\n%s", diff)
	}
	if got := auditCount(t, h, "auth.signed_up"); got != 1 {
		t.Errorf("signed_up audit events = %d, want 1", got)
	}
}

func TestRequestingACodeCreatesNoAccount(t *testing.T) {
	h := newHarness(t)
	request(t, h, testPhone, auth.RoleDriver)

	var users int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 0 {
		t.Errorf("users = %d, want 0 before the code is proven", users)
	}
}

func TestExistingAccountGainsSecondRole(t *testing.T) {
	h := newHarness(t)
	signIn(t, h, testPhone, auth.RoleRider)
	h.clock.Advance(time.Minute)
	tokens := signIn(t, h, testPhone, auth.RoleDriver)

	want := []auth.Role{auth.RoleDriver, auth.RoleRider}
	if diff := cmp.Diff(tokens.Roles, want); diff != "" {
		t.Errorf("roles mismatch (-got +want):\n%s", diff)
	}
	if got := auditCount(t, h, "auth.signed_in"); got != 1 {
		t.Errorf("signed_in audit events = %d, want 1 for the returning user", got)
	}
}

func TestSigningInCannotRestoreRevokedRole(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleDriver)
	_, err := h.pool.Exec(t.Context(), `UPDATE user_roles SET revoked_at = now() WHERE user_id = $1`, tokens.UserID)
	if err != nil {
		t.Fatalf("revoke role: %v", err)
	}

	h.clock.Advance(time.Minute)
	again := signIn(t, h, testPhone, auth.RoleDriver)
	if len(again.Roles) != 0 {
		t.Errorf("roles = %v, want none after revocation", again.Roles)
	}
}

func TestWrongCodesExhaustChallengePermanently(t *testing.T) {
	h := newHarness(t)
	challenge := request(t, h, testPhone, auth.RoleRider)
	correct := h.provider.lastCode()
	wrong := wrongCode(h)

	for attempt := 1; attempt <= 4; attempt++ {
		if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, wrong, testMeta()); !errors.Is(err, auth.ErrInvalidCode) {
			t.Fatalf("attempt %d = %v, want ErrInvalidCode", attempt, err)
		}
	}
	if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, wrong, testMeta()); !errors.Is(err, auth.ErrTooManyAttempts) {
		t.Fatalf("fifth attempt = %v, want ErrTooManyAttempts", err)
	}
	if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, correct, testMeta()); !errors.Is(err, auth.ErrTooManyAttempts) {
		t.Errorf("correct code after lockout = %v, want ErrTooManyAttempts", err)
	}
}

func TestCodeValidity(t *testing.T) {
	t.Run("expires after five minutes", func(t *testing.T) {
		h := newHarness(t)
		challenge := request(t, h, testPhone, auth.RoleRider)
		h.clock.Advance(5 * time.Minute)
		if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, h.provider.lastCode(), testMeta()); !errors.Is(err, auth.ErrCodeExpired) {
			t.Errorf("VerifyOTP = %v, want ErrCodeExpired", err)
		}
	})
	t.Run("works only once", func(t *testing.T) {
		h := newHarness(t)
		challenge := request(t, h, testPhone, auth.RoleRider)
		code := h.provider.lastCode()
		if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, code, testMeta()); err != nil {
			t.Fatalf("first VerifyOTP: %v", err)
		}
		if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, code, testMeta()); !errors.Is(err, auth.ErrCodeExpired) {
			t.Errorf("replay = %v, want ErrCodeExpired", err)
		}
	})
	t.Run("is replaced by a newer code", func(t *testing.T) {
		h := newHarness(t)
		first := request(t, h, testPhone, auth.RoleRider)
		code := h.provider.lastCode()
		h.clock.Advance(time.Minute)
		request(t, h, testPhone, auth.RoleRider)
		if _, err := h.svc.VerifyOTP(t.Context(), first.ID, code, testMeta()); !errors.Is(err, auth.ErrCodeExpired) {
			t.Errorf("old code = %v, want ErrCodeExpired", err)
		}
	})
	t.Run("unknown challenge", func(t *testing.T) {
		h := newHarness(t)
		if _, err := h.svc.VerifyOTP(t.Context(), uuid.New(), "123456", testMeta()); !errors.Is(err, auth.ErrCodeExpired) {
			t.Errorf("VerifyOTP = %v, want ErrCodeExpired", err)
		}
	})
}

func retryAfter(t *testing.T, err error) time.Duration {
	t.Helper()
	limited, ok := errors.AsType[*auth.RateLimitError](err)
	if !ok {
		t.Fatalf("error = %v, want *RateLimitError", err)
	}
	return limited.RetryAfter
}

func TestPhoneRateLimits(t *testing.T) {
	h := newHarness(t)
	otp := auth.OTPRequest{Phone: testPhone, Role: auth.RoleRider, Meta: testMeta()}

	request(t, h, testPhone, auth.RoleRider)
	_, err := h.svc.RequestOTP(t.Context(), otp)
	if got := retryAfter(t, err); got != 30*time.Second {
		t.Errorf("cooldown retry = %v, want 30s", got)
	}

	h.clock.Advance(time.Minute)
	request(t, h, testPhone, auth.RoleRider)
	h.clock.Advance(time.Minute)
	request(t, h, testPhone, auth.RoleRider)

	h.clock.Advance(time.Minute)
	_, err = h.svc.RequestOTP(t.Context(), otp)
	if got := retryAfter(t, err); got != 57*time.Minute {
		t.Errorf("hourly retry = %v, want 57m", got)
	}

	h.clock.Advance(57 * time.Minute)
	request(t, h, testPhone, auth.RoleRider)
}

func TestConcurrentRequestsSendOneCode(t *testing.T) {
	h := newHarness(t)
	var wg sync.WaitGroup
	var succeeded atomic.Int32
	for range 12 {
		wg.Go(func() {
			_, err := h.svc.RequestOTP(t.Context(), auth.OTPRequest{Phone: testPhone, Role: auth.RoleRider, Meta: testMeta()})
			if err == nil {
				succeeded.Add(1)
			}
		})
	}
	wg.Wait()
	if got := succeeded.Load(); got != 1 {
		t.Errorf("successful requests = %d, want 1", got)
	}
	if got := h.provider.sent.Load(); got != 1 {
		t.Errorf("messages sent = %d, want 1", got)
	}
}

func TestIPRateLimit(t *testing.T) {
	h := newHarness(t)
	for i := range 60 {
		request(t, h, fmt.Sprintf("2547000%05d", i), auth.RoleRider)
	}
	_, err := h.svc.RequestOTP(t.Context(), auth.OTPRequest{Phone: "254799999999", Role: auth.RoleRider, Meta: testMeta()})
	retryAfter(t, err)

	other := testMeta()
	other.IP = netip.MustParseAddr("198.51.100.9")
	if _, err := h.svc.RequestOTP(t.Context(), auth.OTPRequest{Phone: "254799999999", Role: auth.RoleRider, Meta: other}); err != nil {
		t.Errorf("other address = %v, want nil", err)
	}
}

func TestProviderFailure(t *testing.T) {
	h := newHarness(t)
	h.provider.down.Store(true)
	otp := auth.OTPRequest{Phone: testPhone, Role: auth.RoleRider, Meta: testMeta()}

	for attempt := range 4 {
		if _, err := h.svc.RequestOTP(t.Context(), otp); !errors.Is(err, auth.ErrDeliveryUnavailable) {
			t.Fatalf("attempt %d = %v, want ErrDeliveryUnavailable", attempt, err)
		}
		h.clock.Advance(time.Minute)
	}

	h.provider.down.Store(false)
	request(t, h, testPhone, auth.RoleRider)

	h.provider.down.Store(true)
	h.clock.Advance(time.Second)
	_, err := h.svc.RequestOTP(t.Context(), otp)
	retryAfter(t, err)
}

func TestBlockedAccountIsToldOnlyAfterProvingTheCode(t *testing.T) {
	h := newHarness(t)
	tokens := signIn(t, h, testPhone, auth.RoleRider)
	setAccountStatus(t, h, tokens.UserID, "banned")

	h.clock.Advance(time.Minute)
	challenge := request(t, h, testPhone, auth.RoleRider)
	if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, wrongCode(h), testMeta()); !errors.Is(err, auth.ErrInvalidCode) {
		t.Errorf("wrong code = %v, want ErrInvalidCode", err)
	}
	if _, err := h.svc.VerifyOTP(t.Context(), challenge.ID, h.provider.lastCode(), testMeta()); !errors.Is(err, auth.ErrAccountBanned) {
		t.Errorf("right code = %v, want ErrAccountBanned", err)
	}
}
