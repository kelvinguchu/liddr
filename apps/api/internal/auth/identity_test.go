package auth_test

import (
	"context"
	"errors"
	"regexp"
	"sync"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

// outbox stands in for Resend at the interface the service consumes. The real
// client has its own test against an HTTP stand-in.
type outbox struct {
	mu   sync.Mutex
	last string
	fail bool
}

var mailCode = regexp.MustCompile(`code is (\d{6})`)

func (o *outbox) Send(_ context.Context, _, _, text string) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.fail {
		return errors.New("provider down")
	}
	o.last = mailCode.FindStringSubmatch(text)[1]
	return nil
}

func (o *outbox) code() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.last
}

func emailHarness(t *testing.T) (*harness, *outbox, *auth.Service) {
	t.Helper()
	h := newHarness(t)
	box := &outbox{}
	return h, box, auth.NewService(auth.Config{Pool: h.pool, Email: box, HMACKey: []byte("test-key-of-sufficient-length-for-hmac"), Now: h.clock.Now})
}

func TestEmailSignIn(t *testing.T) {
	h, box, svc := emailHarness(t)
	challenge, err := svc.RequestEmailOTP(t.Context(), "Rider@Example.com", testMeta())
	if err != nil {
		t.Fatalf("RequestEmailOTP: %v", err)
	}
	if _, err := svc.VerifyEmailOTP(t.Context(), challenge.ID, "000000", testMeta()); !errors.Is(err, auth.ErrInvalidCode) && box.code() != "000000" {
		t.Errorf("wrong code = %v", err)
	}
	tokens, err := svc.VerifyEmailOTP(t.Context(), challenge.ID, box.code(), testMeta())
	if err != nil {
		t.Fatalf("VerifyEmailOTP: %v", err)
	}
	if len(tokens.Roles) != 1 || tokens.Roles[0] != auth.RoleRider {
		t.Errorf("roles = %v", tokens.Roles)
	}
	if _, err := svc.VerifyEmailOTP(t.Context(), challenge.ID, box.code(), testMeta()); !errors.Is(err, auth.ErrCodeExpired) {
		t.Errorf("reused code = %v", err)
	}
	p, err := svc.Authenticate(t.Context(), tokens.AccessToken)
	if err != nil || p.Phone != "" {
		t.Errorf("Authenticate = %+v, %v", p, err)
	}

	h.clock.Advance(time.Minute)
	again, err := svc.RequestEmailOTP(t.Context(), "rider@example.com", testMeta())
	if err != nil {
		t.Fatalf("second request: %v", err)
	}
	second, err := svc.VerifyEmailOTP(t.Context(), again.ID, box.code(), testMeta())
	if err != nil || second.UserID != tokens.UserID {
		t.Errorf("same address made another account: %v, %v", second.UserID, err)
	}
}

func TestEmailLimits(t *testing.T) {
	h, box, svc := emailHarness(t)
	const address = "rider@example.com"
	if _, err := svc.RequestEmailOTP(t.Context(), address, testMeta()); err != nil {
		t.Fatalf("first request: %v", err)
	}
	var limited *auth.RateLimitError
	if _, err := svc.RequestEmailOTP(t.Context(), address, testMeta()); !errors.As(err, &limited) { //nolint:errorlint // Mirrors the handler's check.
		t.Errorf("immediate repeat = %v", err)
	}
	for range 2 {
		h.clock.Advance(31 * time.Second)
		if _, err := svc.RequestEmailOTP(t.Context(), address, testMeta()); err != nil {
			t.Fatalf("request: %v", err)
		}
	}
	h.clock.Advance(31 * time.Second)
	if _, err := svc.RequestEmailOTP(t.Context(), address, testMeta()); !errors.As(err, &limited) {
		t.Errorf("fourth in the hour = %v", err)
	}
	_ = box
}

func TestEmailDeliveryFailureIsAnError(t *testing.T) {
	_, box, svc := emailHarness(t)
	box.fail = true
	if _, err := svc.RequestEmailOTP(t.Context(), "rider@example.com", testMeta()); !errors.Is(err, auth.ErrDeliveryUnavailable) {
		t.Errorf("RequestEmailOTP = %v", err)
	}
}

func TestSignInMethodsReportWhenNotConfigured(t *testing.T) {
	h := newHarness(t)
	if _, err := h.svc.RequestEmailOTP(t.Context(), "a@b.co", testMeta()); !errors.Is(err, auth.ErrEmailUnavailable) {
		t.Errorf("email = %v", err)
	}
	if _, err := h.svc.SignInWithGoogle(t.Context(), "token", testMeta()); !errors.Is(err, auth.ErrGoogleUnavailable) {
		t.Errorf("google = %v", err)
	}
}
