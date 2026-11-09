package config

import (
	"fmt"
	"log/slog"
	"maps"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

const testHMACKey = "0123456789abcdef0123456789abcdef"

// validEnv returns a complete environment with overrides applied. An empty
// override removes the variable.
func validEnv(overrides map[string]string) map[string]string {
	values := map[string]string{
		"DATABASE_URL":               "postgres://user:hunter2@db",
		"AUTH_HMAC_KEY":              testHMACKey,
		"DATA_ENCRYPTION_KEY":        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
		"GOOGLE_MAPS_API_KEY_SERVER": "maps-key",
		"MPESA_CONSUMER_KEY":         "consumer-key",
		"MPESA_CONSUMER_SECRET":      "consumer-secret",
		"MPESA_SHORTCODE":            "174379",
		"MPESA_PASSKEY":              "passkey",
		"MPESA_CALLBACK_BASE_URL":    "https://api.example",
		"MPESA_CALLBACK_TOKEN":       testHMACKey,
		"HOSTPINNACLE_API_URL":       "https://sms.example/send",
		"HOSTPINNACLE_API_KEY":       "api-key",
		"HOSTPINNACLE_USER_ID":       "user",
		"HOSTPINNACLE_PASSWORD":      "password",
		"HOSTPINNACLE_SENDER_ID":     "LIDDR",
	}
	maps.Copy(values, overrides)
	return values
}

func TestLoadAppliesDefaults(t *testing.T) {
	got, err := Load(env(validEnv(nil)))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := Config{
		Addr:            ":8080",
		DatabaseURL:     "postgres://user:hunter2@db",
		DBMaxConns:      20,
		DrainDelay:      5 * time.Second,
		ShutdownTimeout: 20 * time.Second,
		AuthHMACKey:     testHMACKey,
		DataKey:         Secret("\x00\x01\x02\x03\x04\x05\x06\a\b\t\n\v\f\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"),
		Documents:       Documents{BaseURL: "https://storage.googleapis.com"},
		Push:            Push{BaseURL: "https://fcm.googleapis.com", TokenURL: "https://oauth2.googleapis.com/token"},
		GoogleMapsKey:   "maps-key",
		GoogleRoutesURL: "https://routes.googleapis.com",
		Mpesa: Mpesa{
			BaseURL:         "https://sandbox.safaricom.co.ke",
			ConsumerKey:     "consumer-key",
			ConsumerSecret:  "consumer-secret",
			Shortcode:       "174379",
			Passkey:         "passkey",
			TransactionType: "CustomerPayBillOnline",
			CallbackBaseURL: "https://api.example",
			CallbackToken:   testHMACKey,
		},
		SMS: SMS{
			URL:      "https://sms.example/send",
			APIKey:   "api-key",
			UserID:   "user",
			Password: "password",
			SenderID: "LIDDR",
		},
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("config mismatch (-got +want):\n%s", diff)
	}
}

func TestLoadRejectsInvalidValues(t *testing.T) {
	tests := []struct {
		name, key, value, want string
	}{
		{"missing database url", "DATABASE_URL", "", "DATABASE_URL is required"},
		{"missing data key", "DATA_ENCRYPTION_KEY", "", "DATA_ENCRYPTION_KEY is required"},
		{"short data key", "DATA_ENCRYPTION_KEY", "c2hvcnQ=", "DATA_ENCRYPTION_KEY must be base64"},
		{"bad ops range", "OPS_ALLOWED_CIDRS", "not-a-range", "OPS_ALLOWED_CIDRS must be"},
		{"bucket without account", "GCS_BUCKET", "bucket", "GCS_SERVICE_ACCOUNT_JSON is required"},
		{"bucket without scanner", "GCS_BUCKET", "bucket", "CLAMAV_ADDR is required"},
		{"push without account", "FCM_PROJECT_ID", "liddr", "FCM_SERVICE_ACCOUNT_JSON is required"},
		{"missing hmac key", "AUTH_HMAC_KEY", "", "AUTH_HMAC_KEY is required"},
		{"short hmac key", "AUTH_HMAC_KEY", "too-short", "AUTH_HMAC_KEY must be at least"},
		{"missing sms url", "HOSTPINNACLE_API_URL", "", "HOSTPINNACLE_API_URL is required"},
		{"missing sms password", "HOSTPINNACLE_PASSWORD", "", "HOSTPINNACLE_PASSWORD is required"},
		{"short callback token", "MPESA_CALLBACK_TOKEN", "too-short", "MPESA_CALLBACK_TOKEN must be at least"},
		{"unsafe callback token", "MPESA_CALLBACK_TOKEN", "0123456789/abcdef0123456789abcdefgh", "safe to place"},
		{"bad allowed ip", "MPESA_CALLBACK_ALLOWED_IPS", "not-an-ip", "MPESA_CALLBACK_ALLOWED_IPS"},
		{"non-numeric pool", "DB_MAX_CONNS", "many", "DB_MAX_CONNS"},
		{"zero pool", "DB_MAX_CONNS", "0", "DB_MAX_CONNS"},
		{"pool beyond 32 bits", "DB_MAX_CONNS", "9999999999", "DB_MAX_CONNS"},
		{"negative proxy hops", "TRUSTED_PROXY_HOPS", "-1", "TRUSTED_PROXY_HOPS"},
		{"bad drain", "SHUTDOWN_DRAIN_DELAY", "soon", "SHUTDOWN_DRAIN_DELAY"},
		{"negative timeout", "SHUTDOWN_TIMEOUT", "-1s", "SHUTDOWN_TIMEOUT"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Load(env(validEnv(map[string]string{tt.key: tt.value})))
			if err == nil {
				t.Fatal("Load returned nil error")
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %q, want it to mention %q", err, tt.want)
			}
			if strings.Contains(err.Error(), "hunter2") {
				t.Errorf("error leaked the database password: %q", err)
			}
		})
	}
}

func TestLoadReportsEveryProblem(t *testing.T) {
	_, err := Load(env(map[string]string{"DB_MAX_CONNS": "x", "SHUTDOWN_TIMEOUT": "y"}))
	if err == nil {
		t.Fatal("Load returned nil error")
	}
	for _, want := range []string{"DATABASE_URL", "DB_MAX_CONNS", "SHUTDOWN_TIMEOUT"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %q, want it to mention %s", err, want)
		}
	}
}

func TestSecretNeverFormatsItsValue(t *testing.T) {
	s := Secret("hunter2")
	var logged strings.Builder
	slog.New(slog.NewJSONHandler(&logged, nil)).InfoContext(t.Context(), "event", slog.Any("value", s))

	outputs := map[string]string{
		"%v":  fmt.Sprintf("%v", s),
		"%s":  fmt.Sprintf("%s", s), //nolint:staticcheck // This case tests %s formatting itself.
		"%#v": fmt.Sprintf("%#v", s),
		"log": logged.String(),
	}
	for name, got := range outputs {
		if strings.Contains(got, "hunter2") {
			t.Errorf("%s leaked the secret: %q", name, got)
		}
	}
	if got := s.Reveal(); got != "hunter2" {
		t.Errorf("Reveal() = %q, want hunter2", got)
	}
}
