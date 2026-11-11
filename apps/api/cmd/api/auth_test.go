package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

var smsCode = regexp.MustCompile(`code is: (\d{6})`)

// smsStub stands in for Onfon, the only third-party network here.
type smsStub struct {
	mu   sync.Mutex
	code string
}

func (s *smsStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var sent struct {
		MessageParameters []struct {
			Text string `json:"Text"`
		} `json:"MessageParameters"`
	}
	if r.URL.Path != "/v1/sms/SendBulkSMS" || json.NewDecoder(r.Body).Decode(&sent) != nil || len(sent.MessageParameters) != 1 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if match := smsCode.FindStringSubmatch(sent.MessageParameters[0].Text); match != nil {
		s.mu.Lock()
		s.code = match[1]
		s.mu.Unlock()
	}
	_, _ = w.Write([]byte(`{"ErrorCode":0,"ErrorDescription":"Success"}`))
}

func (s *smsStub) lastCode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.code
}

type response struct {
	status int
	header http.Header
	body   map[string]any
}

const headerStepUp = "X-Step-Up-Token"

func send(t *testing.T, method, target, bearer string, payload any) response {
	t.Helper()
	return sendWithHeader(t, method, target, bearer, "", "", payload)
}

func sendWithHeader(t *testing.T, method, target, bearer, headerName, headerValue string, payload any) response {
	t.Helper()
	var body bytes.Buffer
	if payload != nil {
		if err := json.NewEncoder(&body).Encode(payload); err != nil {
			t.Fatalf("encode payload: %v", err)
		}
	}
	req, err := http.NewRequestWithContext(t.Context(), method, target, &body)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if headerName != "" {
		req.Header.Set(headerName, headerValue)
	}
	client := http.Client{Timeout: testTimeout, Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, target, err)
	}
	defer func() { _ = resp.Body.Close() }() // The body has been read by then.
	parsed := response{status: resp.StatusCode, header: resp.Header}
	if resp.StatusCode != http.StatusNoContent {
		if err := json.NewDecoder(resp.Body).Decode(&parsed.body); err != nil {
			t.Fatalf("decode %s response: %v", target, err)
		}
	}
	return parsed
}

// assertDeviceSignedOut proves a signed-out phone stops receiving pushes.
func assertDeviceSignedOut(t *testing.T, databaseURL string) {
	t.Helper()
	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(context.WithoutCancel(t.Context())) }() // Only an assertion used it.
	var active int
	if err := db.QueryRow(t.Context(), `SELECT count(*) FROM push_tokens WHERE revoked_at IS NULL`).Scan(&active); err != nil || active != 0 {
		t.Errorf("devices still registered after logout = %d, %v", active, err)
	}
}

func signIn(t *testing.T, baseURL string, stub *smsStub, phone, role string) map[string]any {
	t.Helper()
	requested := send(t, http.MethodPost, baseURL+"/v1/auth/otp/request", "", map[string]string{"phone": phone, "role": role})
	if requested.status != http.StatusCreated {
		t.Fatalf("request code = %d %v", requested.status, requested.body)
	}
	verified := send(t, http.MethodPost, baseURL+"/v1/auth/otp/verify", "", map[string]any{
		"challenge_id": requested.body["challenge_id"],
		"code":         stub.lastCode(),
	})
	if verified.status != http.StatusOK {
		t.Fatalf("verify code = %d %v", verified.status, verified.body)
	}
	return verified.body
}

func TestSignInLifecycleEndToEnd(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	baseURL, output := startServer(t, databaseURL, provider.URL)

	session := signIn(t, baseURL, stub, "0712 345 678", "driver")
	access, _ := session["access_token"].(string)
	refresh, _ := session["refresh_token"].(string)

	me := send(t, http.MethodGet, baseURL+"/v1/me", access, nil)
	if me.status != http.StatusOK || me.body["phone"] != "254712345678" {
		t.Fatalf("GET /v1/me = %d %v", me.status, me.body)
	}
	if roles, _ := me.body["roles"].([]any); len(roles) != 1 || roles[0] != "driver" {
		t.Errorf("roles = %v, want [driver]", me.body["roles"])
	}

	rotated := send(t, http.MethodPost, baseURL+"/v1/auth/refresh", "", map[string]string{"refresh_token": refresh})
	if rotated.status != http.StatusOK {
		t.Fatalf("refresh = %d %v", rotated.status, rotated.body)
	}
	if got := send(t, http.MethodGet, baseURL+"/v1/me", access, nil); got.status != http.StatusUnauthorized {
		t.Errorf("old access token after rotation = %d, want 401", got.status)
	}

	newAccess, _ := rotated.body["access_token"].(string)
	newRefresh, _ := rotated.body["refresh_token"].(string)
	device := map[string]string{"token": "device-registration-token", "platform": "android"}
	if got := send(t, http.MethodPut, baseURL+"/v1/push-tokens", newAccess, device); got.status != http.StatusNoContent {
		t.Fatalf("register device = %d %v", got.status, got.body)
	}
	logout := send(t, http.MethodPost, baseURL+"/v1/auth/logout", "", map[string]string{"refresh_token": newRefresh})
	if logout.status != http.StatusNoContent {
		t.Fatalf("logout = %d %v", logout.status, logout.body)
	}
	if got := send(t, http.MethodGet, baseURL+"/v1/me", newAccess, nil); got.status != http.StatusUnauthorized {
		t.Errorf("access token after logout = %d, want 401", got.status)
	}

	assertDeviceSignedOut(t, databaseURL)

	logs := output.String()
	for _, secret := range []string{access, refresh, newAccess, newRefresh, stub.lastCode(), "254712345678"} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs leaked %q", secret)
		}
	}
}

func TestProtectedRoutesRejectBadCredentials(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	baseURL, _ := startServer(t, databaseURL, "")

	for name, bearer := range map[string]string{"no token": "", "unknown token": "forged-token"} {
		t.Run(name, func(t *testing.T) {
			got := send(t, http.MethodGet, baseURL+"/v1/me", bearer, nil)
			if got.status != http.StatusUnauthorized || got.body["code"] != "UNAUTHORIZED" {
				t.Errorf("GET /v1/me = %d %v, want 401 UNAUTHORIZED", got.status, got.body)
			}
			if got.header.Get("WWW-Authenticate") != "Bearer" {
				t.Errorf("WWW-Authenticate = %q", got.header.Get("WWW-Authenticate"))
			}
		})
	}
}

func TestRequestOTPReportsRetryAfterAndBadInput(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	baseURL, _ := startServer(t, databaseURL, provider.URL)
	target := baseURL + "/v1/auth/otp/request"

	bad := send(t, http.MethodPost, target, "", map[string]string{"phone": "not a phone", "role": "rider"})
	if bad.status != http.StatusBadRequest || bad.body["code"] != "INVALID_PHONE" {
		t.Errorf("bad phone = %d %v", bad.status, bad.body)
	}
	privileged := send(t, http.MethodPost, target, "", map[string]string{"phone": "0712345678", "role": "admin"})
	if privileged.status != http.StatusBadRequest || privileged.body["code"] != "INVALID_ROLE" {
		t.Errorf("admin role = %d %v", privileged.status, privileged.body)
	}

	first := send(t, http.MethodPost, target, "", map[string]string{"phone": "0712345678", "role": "rider"})
	if first.status != http.StatusCreated {
		t.Fatalf("first request = %d %v", first.status, first.body)
	}
	second := send(t, http.MethodPost, target, "", map[string]string{"phone": "0712345678", "role": "rider"})
	if second.status != http.StatusTooManyRequests || second.body["code"] != "RATE_LIMITED" {
		t.Fatalf("second request = %d %v", second.status, second.body)
	}
	if seconds, err := strconv.Atoi(second.header.Get("Retry-After")); err != nil || seconds < 1 {
		t.Errorf("Retry-After = %q", second.header.Get("Retry-After"))
	}
}
