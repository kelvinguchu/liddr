package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func grantStaff(t *testing.T, databaseURL, phone, role string) {
	t.Helper()
	output := &capture{addr: make(chan string, 1)}
	if err := run(t.Context(), []string{"api", "grant-role", phone, role}, envFor(databaseURL, ""), output, io.Discard); err != nil {
		t.Fatalf("grant-role: %v", err)
	}
}

func totpAt(t *testing.T, secret string, at time.Time) string {
	t.Helper()
	code, err := auth.TOTPCode(secret, at)
	if err != nil {
		t.Fatalf("totp code: %v", err)
	}
	return code
}

// enrolStaff signs a staff member in and activates an authenticator. It returns
// the access token and the secret.
func enrolStaff(t *testing.T, baseURL string, stub *smsStub, phone string) (token, secret string) {
	t.Helper()
	token, _ = signIn(t, baseURL, stub, phone, "staff")["access_token"].(string)
	setup := send(t, http.MethodPost, baseURL+"/v1/auth/mfa/totp/setup", token, nil)
	if setup.status != http.StatusCreated {
		t.Fatalf("setup = %d %v", setup.status, setup.body)
	}
	secret, _ = setup.body["secret"].(string)
	confirm := send(t, http.MethodPost, baseURL+"/v1/auth/mfa/totp/confirm", token, map[string]string{"code": totpAt(t, secret, time.Now())})
	if confirm.status != http.StatusNoContent {
		t.Fatalf("confirm = %d %v", confirm.status, confirm.body)
	}
	return token, secret
}

// stepUp spends the code one period ahead, which is accepted as clock drift and
// is the only code not already used by enrolment.
func stepUp(t *testing.T, baseURL, token, secret string, offset time.Duration) string {
	t.Helper()
	got := send(t, http.MethodPost, baseURL+"/v1/auth/step-up", token, map[string]string{"code": totpAt(t, secret, time.Now().Add(offset))})
	if got.status != http.StatusOK {
		t.Fatalf("step-up = %d %v", got.status, got.body)
	}
	value, _ := got.body["step_up_token"].(string)
	return value
}

func TestStaffTwoFactor(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	baseURL, _ := startServer(t, databaseURL, provider.URL)
	grantStaff(t, databaseURL, "0700000001", "ops")

	requested := send(t, http.MethodPost, baseURL+"/v1/auth/otp/request", "", map[string]string{"phone": "0700000099", "role": "staff"})
	refused := send(t, http.MethodPost, baseURL+"/v1/auth/otp/verify", "", map[string]any{"challenge_id": requested.body["challenge_id"], "code": stub.lastCode()})
	if refused.status != http.StatusForbidden || refused.body["code"] != "NOT_STAFF" {
		t.Fatalf("staff sign-in for ordinary number = %d %v", refused.status, refused.body)
	}

	rider, _ := signIn(t, baseURL, stub, "0700000002", "rider")["access_token"].(string)
	if got := send(t, http.MethodPost, baseURL+"/v1/auth/mfa/totp/setup", rider, nil); got.status != http.StatusForbidden {
		t.Errorf("rider enrolling = %d, want 403", got.status)
	}

	token, secret := enrolStaff(t, baseURL, stub, "0700000001")

	replayed := send(t, http.MethodPost, baseURL+"/v1/auth/step-up", token, map[string]string{"code": totpAt(t, secret, time.Now())})
	if replayed.status != http.StatusBadRequest {
		t.Errorf("the code that confirmed enrolment passed step-up: %d %v", replayed.status, replayed.body)
	}

	grant := stepUp(t, baseURL, token, secret, 30*time.Second)
	if again := send(t, http.MethodPost, baseURL+"/v1/auth/step-up", token, map[string]string{"code": totpAt(t, secret, time.Now().Add(30*time.Second))}); again.status != http.StatusBadRequest {
		t.Errorf("reused step-up code = %d %v", again.status, again.body)
	}

	if got := send(t, http.MethodPost, baseURL+"/v1/auth/mfa/totp/setup", token, nil); got.status != http.StatusForbidden || got.body["code"] != "STEP_UP_REQUIRED" {
		t.Errorf("replacing without step-up = %d %v", got.status, got.body)
	}
	replaced := sendWithHeader(t, http.MethodPost, baseURL+"/v1/auth/mfa/totp/setup", token, headerStepUp, grant, nil)
	if replaced.status != http.StatusCreated {
		t.Errorf("replacing with step-up = %d %v", replaced.status, replaced.body)
	}

	// One failure is already on record from the reused code above, so the fifth
	// in a row is the fourth here.
	for attempt := range 4 {
		got := send(t, http.MethodPost, baseURL+"/v1/auth/step-up", token, map[string]string{"code": "000000"})
		want := http.StatusBadRequest
		if attempt == 3 {
			want = http.StatusTooManyRequests
		}
		if got.status != want {
			t.Errorf("wrong code %d = %d, want %d", attempt, got.status, want)
		}
	}
	if got := send(t, http.MethodPost, baseURL+"/v1/auth/step-up", token, map[string]string{"code": totpAt(t, secret, time.Now())}); got.status != http.StatusTooManyRequests {
		t.Errorf("correct code while locked = %d, want 429", got.status)
	}
}
