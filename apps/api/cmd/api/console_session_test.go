package main

import (
	"bytes"
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

const consoleOrigin = "https://ops.example"

// browser is a browser on the staff console's origin. It keeps the cookies the
// API sets, the way a browser would, so no test ever handles a token.
type browser struct {
	t       *testing.T
	base    string
	cookies map[string]string
}

type consoleRequest struct {
	method string
	path   string
	body   any
	// crossSite sends the request as another site would: no console header,
	// a foreign Origin and Sec-Fetch-Site cross-site.
	crossSite bool
}

func (c *browser) do(req consoleRequest) response {
	c.t.Helper()
	var body bytes.Buffer
	if req.body != nil {
		if err := json.NewEncoder(&body).Encode(req.body); err != nil {
			c.t.Fatalf("encode payload: %v", err)
		}
	}
	r, err := http.NewRequestWithContext(c.t.Context(), req.method, c.base+req.path, &body)
	if err != nil {
		c.t.Fatalf("build request: %v", err)
	}
	r.Header.Set("Content-Type", "application/json")
	if req.crossSite {
		r.Header.Set("Origin", "https://evil.example")
		r.Header.Set("Sec-Fetch-Site", "cross-site")
	} else {
		r.Header.Set("Origin", consoleOrigin)
		r.Header.Set("Sec-Fetch-Site", "same-origin")
		r.Header.Set("X-Liddr-Console", "1")
	}
	for name, value := range c.cookies {
		r.AddCookie(&http.Cookie{Name: name, Value: value}) //nolint:gosec // A request cookie: only its name and value are sent.
	}
	client := http.Client{Timeout: testTimeout, Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Do(r)
	if err != nil {
		c.t.Fatalf("%s %s: %v", req.method, req.path, err)
	}
	defer func() { _ = resp.Body.Close() }() // The body has been read by then.
	for _, cookie := range resp.Cookies() {
		if cookie.MaxAge < 0 || cookie.Value == "" {
			delete(c.cookies, cookie.Name)
			continue
		}
		c.cookies[cookie.Name] = cookie.Value
	}
	parsed := response{status: resp.StatusCode, header: resp.Header}
	if resp.StatusCode != http.StatusNoContent {
		if err := json.NewDecoder(resp.Body).Decode(&parsed.body); err != nil {
			c.t.Fatalf("decode %s response: %v", req.path, err)
		}
	}
	return parsed
}

// signIn requests a staff code and exchanges it for a console session.
func (c *browser) signIn(stub *smsStub, phone, role string) response {
	c.t.Helper()
	requested := send(c.t, http.MethodPost, c.base+"/v1/auth/otp/request", "", map[string]string{"phone": phone, "role": role})
	if requested.status != http.StatusCreated {
		c.t.Fatalf("request code = %d %v", requested.status, requested.body)
	}
	return c.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/web/session", body: map[string]any{
		"challenge_id": requested.body["challenge_id"],
		"code":         stub.lastCode(),
	}})
}

func TestStaffConsoleSession(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	baseURL, _ := startServerWithEnv(t, databaseURL, provider.URL, "http://127.0.0.1:1", map[string]string{"OPS_CONSOLE_ORIGIN": consoleOrigin})
	grantStaff(t, databaseURL, "0700000001", "ops")

	rider := &browser{t: t, base: baseURL, cookies: map[string]string{}}
	if got := rider.signIn(stub, "0700000002", "rider"); got.status != http.StatusForbidden || got.body["code"] != "NOT_STAFF" || len(rider.cookies) != 0 {
		t.Fatalf("rider console sign-in = %d %v, cookies %v", got.status, got.body, rider.cookies)
	}

	staff := &browser{t: t, base: baseURL, cookies: map[string]string{}}
	requested := send(t, http.MethodPost, baseURL+"/v1/auth/otp/request", "", map[string]string{"phone": "0700000001", "role": "staff"})
	forged := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/web/session", crossSite: true,
		body: map[string]any{"challenge_id": requested.body["challenge_id"], "code": stub.lastCode()}})
	if forged.status != http.StatusForbidden || forged.body["code"] != "CONSOLE_ORIGIN_REQUIRED" {
		t.Fatalf("cross-site sign-in = %d %v", forged.status, forged.body)
	}

	// The refused attempt never reached the code check, so the code still works.
	signedIn := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/web/session",
		body: map[string]any{"challenge_id": requested.body["challenge_id"], "code": stub.lastCode()}})
	if signedIn.status != http.StatusOK {
		t.Fatalf("console sign-in = %d %v", signedIn.status, signedIn.body)
	}
	if _, leaked := signedIn.body["access_token"]; leaked {
		t.Errorf("console sign-in returned a token in its body: %v", signedIn.body)
	}
	assertSessionCookies(t, signedIn.header)

	if me := staff.do(consoleRequest{method: http.MethodGet, path: "/v1/me"}); me.status != http.StatusOK || me.body["phone"] == nil {
		t.Fatalf("me by cookie = %d %v", me.status, me.body)
	}
	if got := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/mfa/totp/setup", crossSite: true}); got.status != http.StatusForbidden || got.body["code"] != "CONSOLE_ORIGIN_REQUIRED" {
		t.Errorf("cross-site write with the session cookie = %d %v", got.status, got.body)
	}

	setup := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/mfa/totp/setup"})
	if setup.status != http.StatusCreated {
		t.Fatalf("enrol by cookie = %d %v", setup.status, setup.body)
	}
	secret, _ := setup.body["secret"].(string)
	if got := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/mfa/totp/confirm", body: map[string]string{"code": totpAt(t, secret, time.Now())}}); got.status != http.StatusNoContent {
		t.Fatalf("confirm by cookie = %d %v", got.status, got.body)
	}

	lift := "/v1/ops/moderation/enforcements/" + uuid.NewString() + "/lift"
	if got := staff.do(consoleRequest{method: http.MethodPost, path: lift}); got.status != http.StatusForbidden || got.body["code"] != "STEP_UP_REQUIRED" {
		t.Errorf("high-risk action without step-up = %d %v", got.status, got.body)
	}
	grant := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/web/step-up", body: map[string]string{"code": totpAt(t, secret, time.Now().Add(30*time.Second))}})
	if grant.status != http.StatusOK || grant.body["expires_in"] == nil {
		t.Fatalf("console step-up = %d %v", grant.status, grant.body)
	}
	if _, leaked := grant.body["step_up_token"]; leaked {
		t.Errorf("console step-up returned the token in its body: %v", grant.body)
	}
	if got := staff.do(consoleRequest{method: http.MethodPost, path: lift}); got.status != http.StatusNotFound {
		t.Errorf("high-risk action after console step-up = %d %v, want 404 for an unknown penalty", got.status, got.body)
	}

	before := staff.cookies["__Host-liddr_staff"]
	if got := staff.do(consoleRequest{method: http.MethodPost, path: "/v1/auth/web/session/refresh"}); got.status != http.StatusOK {
		t.Fatalf("refresh = %d %v", got.status, got.body)
	}
	if after := staff.cookies["__Host-liddr_staff"]; after == "" || after == before {
		t.Errorf("refresh did not rotate the session cookie")
	}
	if _, kept := staff.cookies["__Host-liddr_step_up"]; kept {
		t.Errorf("refresh kept a step-up cookie bound to the old session")
	}

	kept := maps.Clone(staff.cookies)
	if got := staff.do(consoleRequest{method: http.MethodDelete, path: "/v1/auth/web/session"}); got.status != http.StatusNoContent || len(staff.cookies) != 0 {
		t.Fatalf("sign out = %d, cookies left %v", got.status, staff.cookies)
	}
	replay := &browser{t: t, base: baseURL, cookies: kept}
	if got := replay.do(consoleRequest{method: http.MethodGet, path: "/v1/me"}); got.status != http.StatusUnauthorized {
		t.Errorf("session cookie after sign-out = %d %v", got.status, got.body)
	}
}

func assertSessionCookies(t *testing.T, header http.Header) {
	t.Helper()
	seen := map[string]*http.Cookie{}
	for _, cookie := range (&http.Response{Header: header}).Cookies() {
		seen[cookie.Name] = cookie
	}
	for name, path := range map[string]string{"__Host-liddr_staff": "/", "__Secure-liddr_staff_refresh": "/v1/auth/web/session"} {
		cookie := seen[name]
		switch {
		case cookie == nil:
			t.Errorf("no %s cookie in %v", name, header.Values("Set-Cookie"))
		case !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != path || cookie.Domain != "":
			t.Errorf("%s = %q, want HttpOnly, Secure, SameSite=Strict, host-only, path %s", name, cookie.Raw, path)
		}
	}
}

func TestConsoleSessionIsOffWithoutAnOrigin(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	baseURL, _ := startServer(t, databaseURL, "")
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPost, baseURL+"/v1/auth/web/session", strings.NewReader(`{"challenge_id":"`+uuid.NewString()+`","code":"123456"}`))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Origin", consoleOrigin)
	req.Header.Set("X-Liddr-Console", "1")
	client := http.Client{Timeout: testTimeout}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	_ = resp.Body.Close() // Only the status and headers matter.
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("console sign-in without OPS_CONSOLE_ORIGIN = %d", resp.StatusCode)
	}
	if len(resp.Cookies()) != 0 {
		t.Errorf("cookies set while the console is off: %v", resp.Header.Values("Set-Cookie"))
	}
}
