package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
	"go.uber.org/goleak"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

const (
	testTimeout       = 30 * time.Second
	testCallbackToken = "test-callback-token-of-sufficient-length"
)

func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}

// capture records process output and publishes the address the server bound.
type capture struct {
	mu   sync.Mutex
	logs strings.Builder
	addr chan string
}

func (c *capture) Write(p []byte) (int, error) {
	var entry struct {
		Msg  string `json:"msg"`
		Addr string `json:"addr"`
	}
	if json.Unmarshal(p, &entry) == nil && entry.Msg == "http server listening" {
		c.addr <- entry.Addr
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logs.Write(p)
}

func (c *capture) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.logs.String()
}

func envFor(databaseURL, smsURL string) func(string) string {
	return envWithRoutes(databaseURL, smsURL, "http://127.0.0.1:1")
}

func envWithRoutes(databaseURL, smsURL, routesURL string) func(string) string {
	values := map[string]string{
		"ADDR":                       "127.0.0.1:0",
		"DATABASE_URL":               databaseURL,
		"DB_MAX_CONNS":               "4",
		"SHUTDOWN_DRAIN_DELAY":       "0s",
		"SHUTDOWN_TIMEOUT":           "5s",
		"AUTH_HMAC_KEY":              "integration-test-key-of-sufficient-length",
		"DATA_ENCRYPTION_KEY":        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
		"GOOGLE_MAPS_API_KEY_SERVER": "test-maps-key",
		"GOOGLE_ROUTES_BASE_URL":     routesURL,
		"MPESA_CONSUMER_KEY":         "test-consumer-key",
		"MPESA_CONSUMER_SECRET":      "test-consumer-secret",
		"MPESA_SHORTCODE":            "174379",
		"MPESA_PASSKEY":              "test-passkey",
		"MPESA_BASE_URL":             "http://127.0.0.1:1",
		"MPESA_CALLBACK_BASE_URL":    "https://api.example",
		"MPESA_CALLBACK_TOKEN":       testCallbackToken,
		"ONFON_API_URL":              withDefaultURL(smsURL),
		"ONFON_API_KEY":              "test-key",
		"ONFON_CLIENT_ID":            "test-client",
		"ONFON_ACCESS_KEY":           "test-access-key",
		"ONFON_SENDER_ID":            "LIDDR",
	}
	return func(key string) string { return values[key] }
}

// withDefaultURL gives tests that send no SMS an address that refuses connections.
func withDefaultURL(smsURL string) string {
	if smsURL == "" {
		return "http://127.0.0.1:1"
	}
	return smsURL
}

// startServer runs the real process entry point and stops it at test end,
// failing the test unless shutdown is clean.
func startServer(t *testing.T, databaseURL, smsURL string) (string, *capture) {
	t.Helper()
	return startServerWithRoutes(t, databaseURL, smsURL, "http://127.0.0.1:1")
}

func startServerWithRoutes(t *testing.T, databaseURL, smsURL, routesURL string) (string, *capture) {
	t.Helper()
	return startServerWithEnv(t, databaseURL, smsURL, routesURL, nil)
}

func startServerWithEnv(t *testing.T, databaseURL, smsURL, routesURL string, extra map[string]string) (string, *capture) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	output := &capture{addr: make(chan string, 1)}
	done := make(chan error, 1)
	base := envWithRoutes(databaseURL, smsURL, routesURL)
	env := func(key string) string {
		if value, ok := extra[key]; ok {
			return value
		}
		return base(key)
	}
	go func() { done <- run(ctx, []string{"api", "serve"}, env, output, io.Discard) }()

	t.Cleanup(func() {
		cancel()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("run returned %v after shutdown", err)
			}
		case <-time.After(testTimeout):
			t.Error("server did not stop before the deadline")
		}
	})

	select {
	case addr := <-output.addr:
		return "http://" + addr, output
	case err := <-done:
		done <- err
		t.Fatalf("server exited during startup: %v", err)
	case <-time.After(testTimeout):
		t.Fatal("server did not start before the deadline")
	}
	return "", nil
}

func TestVehicleCategoriesEndToEnd(t *testing.T) {
	databaseURL := testdb.URL(t)
	if got := migrate(t, databaseURL); strings.Contains(got, `"count":0`) {
		t.Errorf("first migrate output = %s, want migrations applied", got)
	}
	if got := migrate(t, databaseURL); !strings.Contains(got, `"count":0`) {
		t.Errorf("second migrate output = %s, want none applied", got)
	}
	baseURL, _ := startServer(t, databaseURL, "")

	if status, _, body := get(t, baseURL+"/readyz"); status != http.StatusOK {
		t.Errorf("GET /readyz = %d %s, want 200", status, body)
	}

	status, headers, body := get(t, baseURL+"/v1/vehicle-categories")
	if status != http.StatusOK {
		t.Fatalf("GET /v1/vehicle-categories = %d %s, want 200", status, body)
	}
	if got := headers.Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}

	type category struct {
		Slug                  string `json:"slug"`
		Label                 string `json:"label"`
		Capacity              int    `json:"capacity"`
		WeeklySubscriptionKES int    `json:"weekly_subscription_kes"`
	}
	var got struct {
		Data []category `json:"data"`
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&got); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	want := []category{
		{"motorbike", "Motorbike", 1, 1000},
		{"electric_motorbike", "Electric Motorbike", 1, 1000},
		{"basic", "Basic", 3, 2000},
		{"send", "Send", 0, 1500},
	}
	if diff := cmp.Diff(got.Data, want); diff != "" {
		t.Errorf("categories mismatch (-got +want):\n%s", diff)
	}
}

func TestServeWithUnreachableDatabase(t *testing.T) {
	const password = "hunter2"
	baseURL, output := startServer(t, "postgres://liddr:"+password+"@127.0.0.1:1/liddr?connect_timeout=1", "")

	if status, _, body := get(t, baseURL+"/healthz"); status != http.StatusOK {
		t.Errorf("GET /healthz = %d %s, want 200", status, body)
	}
	if status, _, body := get(t, baseURL+"/readyz"); status != http.StatusServiceUnavailable {
		t.Errorf("GET /readyz = %d %s, want 503", status, body)
	}
	if status, _, body := get(t, baseURL+"/does-not-exist"); status != http.StatusNotFound {
		t.Errorf("GET /does-not-exist = %d %s, want 404", status, body)
	}
	if strings.Contains(output.String(), password) {
		t.Errorf("logs leaked the database password: %s", output)
	}
}

func TestRunRejectsBadInvocations(t *testing.T) {
	tests := []struct {
		name string
		args []string
		env  func(string) string
		want string
	}{
		{"no command", []string{"api"}, envFor("postgres://db", ""), "invalid command"},
		{"unknown command", []string{"api", "deploy"}, envFor("postgres://db", ""), "invalid command"},
		{"extra argument", []string{"api", "serve", "now"}, envFor("postgres://db", ""), "invalid command"},
		{"missing config", []string{"api", "serve"}, func(string) string { return "" }, "DATABASE_URL is required"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := run(t.Context(), tt.args, tt.env, io.Discard, io.Discard)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("run error = %v, want it to mention %q", err, tt.want)
			}
		})
	}
}
