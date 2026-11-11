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
		"ONFON_API_KEY":              "api-key",
		"ONFON_CLIENT_ID":            "client-id",
		"ONFON_ACCESS_KEY":           "access-key",
		"ONFON_SENDER_ID":            "LIDDR",
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
		Documents:       Documents{},
		Email:           Email{URL: "https://api.resend.com/emails"},
		GoogleCertsURL:  "https://www.googleapis.com/oauth2/v3/certs",
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
			BaseURL:   "https://api.onfonmedia.co.ke",
			APIKey:    "api-key",
			ClientID:  "client-id",
			AccessKey: "access-key",
			SenderID:  "LIDDR",
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
		{"console origin with a path", "OPS_CONSOLE_ORIGIN", "https://ops.example.com/app", "OPS_CONSOLE_ORIGIN must be"},
		{"console origin without a scheme", "OPS_CONSOLE_ORIGIN", "ops.example.com", "OPS_CONSOLE_ORIGIN must be"},
		{"bucket without account id", "R2_BUCKET", "bucket", "R2_ACCOUNT_ID must be"},
		{"bucket without token", "R2_BUCKET", "bucket", "R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY are required"},
		{"bucket without scanner", "R2_BUCKET", "bucket", "CLAMAV_ADDR is required"},
		{"push without account", "FCM_PROJECT_ID", "liddr", "FCM_SERVICE_ACCOUNT_JSON is required"},
		{"email without sender", "RESEND_API_KEY", "key", "OTP_EMAIL_FROM is required"},
		{"missing hmac key", "AUTH_HMAC_KEY", "", "AUTH_HMAC_KEY is required"},
		{"short hmac key", "AUTH_HMAC_KEY", "too-short", "AUTH_HMAC_KEY must be at least"},
		{"missing sms access key", "ONFON_ACCESS_KEY", "", "ONFON_ACCESS_KEY is required"},
		{"missing sms sender", "ONFON_SENDER_ID", "", "ONFON_SENDER_ID is required"},
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

// Sandbox has one public test till and passkey, so they need not be set; a
// live till must always name its own.
func TestMpesaTillDefaultsOnlyInSandbox(t *testing.T) {
	tests := []struct {
		name, env   string
		wantErr     string
		wantShort   string
		wantPasskey Secret
	}{
		{name: "sandbox", env: "sandbox", wantShort: "174379", wantPasskey: sandboxPasskey},
		{name: "unset means sandbox", env: "", wantShort: "174379", wantPasskey: sandboxPasskey},
		{name: "production", env: "production", wantErr: "MPESA_SHORTCODE is required"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := Load(env(validEnv(map[string]string{"MPESA_ENV": tt.env, "MPESA_SHORTCODE": "", "MPESA_PASSKEY": ""})))
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) || !strings.Contains(err.Error(), "MPESA_PASSKEY is required") {
					t.Fatalf("Load error = %v, want %q and MPESA_PASSKEY", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if cfg.Mpesa.Shortcode != tt.wantShort || cfg.Mpesa.Passkey != tt.wantPasskey {
				t.Errorf("till = %q, passkey set = %v; want %q and the public sandbox passkey", cfg.Mpesa.Shortcode, cfg.Mpesa.Passkey != "", tt.wantShort)
			}
		})
	}
}

// DATABASE_URL may be written in terms of the POSTGRES_* settings, so one set
// of credentials serves both the database container and the API.
func TestDatabaseURLExpandsReferences(t *testing.T) {
	tests := []struct {
		name, url, want string
		extra           map[string]string
	}{
		{
			name:  "composed",
			url:   "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:55432/${POSTGRES_DB}?sslmode=disable",
			extra: map[string]string{"POSTGRES_USER": "liddr", "POSTGRES_PASSWORD": "pw", "POSTGRES_DB": "rides"},
			want:  "postgresql://liddr:pw@127.0.0.1:55432/rides?sslmode=disable",
		},
		{name: "plain", url: "postgres://a:b@h/d", want: "postgres://a:b@h/d"},
		{name: "a lone dollar stays", url: "postgres://a:pa$s@h/d", want: "postgres://a:pa$s@h/d"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			values := map[string]string{"DATABASE_URL": tt.url}
			maps.Copy(values, tt.extra)
			got, err := LoadDatabaseURL(env(values))
			if err != nil {
				t.Fatalf("LoadDatabaseURL: %v", err)
			}
			if string(got) != tt.want {
				t.Errorf("LoadDatabaseURL = %q, want %q", got.Reveal(), tt.want)
			}
			cfg, err := Load(env(validEnv(values)))
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if string(cfg.DatabaseURL) != tt.want {
				t.Errorf("Load DatabaseURL = %q, want %q", cfg.DatabaseURL.Reveal(), tt.want)
			}
		})
	}
}

func TestDatabaseURLWithAMissingReference(t *testing.T) {
	_, err := LoadDatabaseURL(env(map[string]string{"DATABASE_URL": "postgres://${POSTGRES_USER}@h/d"}))
	if err == nil || !strings.Contains(err.Error(), "POSTGRES_USER") {
		t.Errorf("LoadDatabaseURL error = %v, want it to name POSTGRES_USER", err)
	}
}
