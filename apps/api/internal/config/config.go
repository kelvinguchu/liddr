// Package config reads process configuration from the environment.
package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

const redacted = "[redacted]"

// Secret holds a sensitive string and redacts itself in logs and formatting.
type Secret string

// Reveal returns the underlying value for the one call that needs it.
func (s Secret) Reveal() string { return string(s) }

// String redacts the value so that %v and %s cannot print it.
func (Secret) String() string { return redacted }

// GoString redacts the value so that %#v cannot print it.
func (Secret) GoString() string { return redacted }

// LogValue redacts the value in structured logs.
func (Secret) LogValue() slog.Value { return slog.StringValue(redacted) }

const (
	minHMACKeyBytes = 32
	dataKeyBytes    = 32
)

// SMS holds HostPinnacle credentials.
type SMS struct {
	URL      string
	APIKey   Secret
	UserID   string
	Password Secret
	SenderID string
}

// Mpesa holds Daraja settings.
type Mpesa struct {
	BaseURL         string
	ConsumerKey     Secret
	ConsumerSecret  Secret
	Shortcode       string
	Passkey         Secret
	TransactionType string
	CallbackBaseURL string
	CallbackToken   Secret
	AllowedIPs      []netip.Addr
}

// Config is the validated configuration of the API server.
type Config struct {
	Addr             string
	DatabaseURL      Secret
	DBMaxConns       int32
	DrainDelay       time.Duration
	ShutdownTimeout  time.Duration
	TrustedProxyHops int
	AuthHMACKey      Secret
	DataKey          Secret
	OpsAllowedNets   []netip.Prefix
	Documents        Documents
	Push             Push
	SMS              SMS
	GoogleMapsKey    Secret
	GoogleRoutesURL  string
	Mpesa            Mpesa
	RealtimeOrigins  []string
}

// LoadDatabaseURL returns the only setting that migrations need.
func LoadDatabaseURL(getenv func(string) string) (Secret, error) {
	url := Secret(getenv("DATABASE_URL"))
	if url == "" {
		return "", errors.New("DATABASE_URL is required")
	}
	return url, nil
}

// Push configures Firebase. An empty ProjectID leaves notifications in the app
// inbox, and the server logs that at startup.
type Push struct {
	ProjectID      string
	ServiceAccount Secret
	BaseURL        string
	TokenURL       string
}

// Documents configures driver document storage. An empty Bucket means uploads
// are unavailable: the server starts, and upload routes report that they cannot
// serve. Once a bucket is set, the scanner and credentials are mandatory.
type Documents struct {
	Bucket         string
	BaseURL        string
	ServiceAccount Secret
	ClamAVAddr     string
}

// Load validates the environment and reports every problem at once. Errors
// name the variable and never include its value.
func Load(getenv func(string) string) (Config, error) {
	var errs []error
	required := func(name string) string {
		value := getenv(name)
		if value == "" {
			errs = append(errs, fmt.Errorf("%s is required", name))
		}
		return value
	}

	cfg := Config{
		Addr:            withDefault(getenv("ADDR"), ":8080"),
		DatabaseURL:     Secret(required("DATABASE_URL")),
		AuthHMACKey:     Secret(required("AUTH_HMAC_KEY")),
		DataKey:         decodeDataKey(required("DATA_ENCRYPTION_KEY"), &errs),
		GoogleMapsKey:   Secret(required("GOOGLE_MAPS_API_KEY_SERVER")),
		GoogleRoutesURL: withDefault(getenv("GOOGLE_ROUTES_BASE_URL"), "https://routes.googleapis.com"),
		SMS: SMS{
			URL:      required("HOSTPINNACLE_API_URL"),
			APIKey:   Secret(required("HOSTPINNACLE_API_KEY")),
			UserID:   required("HOSTPINNACLE_USER_ID"),
			Password: Secret(required("HOSTPINNACLE_PASSWORD")),
			SenderID: required("HOSTPINNACLE_SENDER_ID"),
		},
	}
	for origin := range strings.SplitSeq(getenv("REALTIME_ALLOWED_ORIGINS"), ",") {
		if origin = strings.TrimSpace(origin); origin != "" {
			if origin == "*" {
				errs = append(errs, errors.New("REALTIME_ALLOWED_ORIGINS must list exact origins"))
				continue
			}
			cfg.RealtimeOrigins = append(cfg.RealtimeOrigins, origin)
		}
	}
	cfg.Mpesa = Mpesa{
		BaseURL:         withDefault(getenv("MPESA_BASE_URL"), mpesaBaseURL(getenv("MPESA_ENV"))),
		ConsumerKey:     Secret(required("MPESA_CONSUMER_KEY")),
		ConsumerSecret:  Secret(required("MPESA_CONSUMER_SECRET")),
		Shortcode:       required("MPESA_SHORTCODE"),
		Passkey:         Secret(required("MPESA_PASSKEY")),
		TransactionType: withDefault(getenv("MPESA_STK_TRANSACTION_TYPE"), "CustomerPayBillOnline"),
		CallbackBaseURL: required("MPESA_CALLBACK_BASE_URL"),
		CallbackToken:   Secret(required("MPESA_CALLBACK_TOKEN")),
	}
	if cfg.Mpesa.CallbackToken != "" && len(cfg.Mpesa.CallbackToken) < minHMACKeyBytes {
		errs = append(errs, fmt.Errorf("MPESA_CALLBACK_TOKEN must be at least %d bytes", minHMACKeyBytes))
	}
	if strings.ContainsAny(string(cfg.Mpesa.CallbackToken), "/?#% ") {
		errs = append(errs, errors.New("MPESA_CALLBACK_TOKEN must be safe to place in a URL path"))
	}
	for field := range strings.SplitSeq(getenv("MPESA_CALLBACK_ALLOWED_IPS"), ",") {
		if field = strings.TrimSpace(field); field == "" {
			continue
		}
		addr, err := netip.ParseAddr(field)
		if err != nil {
			errs = append(errs, errors.New("MPESA_CALLBACK_ALLOWED_IPS must be comma-separated IP addresses"))
			continue
		}
		cfg.Mpesa.AllowedIPs = append(cfg.Mpesa.AllowedIPs, addr.Unmap())
	}
	if cfg.AuthHMACKey != "" && len(cfg.AuthHMACKey) < minHMACKeyBytes {
		errs = append(errs, fmt.Errorf("AUTH_HMAC_KEY must be at least %d bytes", minHMACKeyBytes))
	}

	for field := range strings.SplitSeq(getenv("OPS_ALLOWED_CIDRS"), ",") {
		if field = strings.TrimSpace(field); field == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(field)
		if err != nil {
			errs = append(errs, errors.New("OPS_ALLOWED_CIDRS must be comma-separated CIDR ranges"))
			continue
		}
		cfg.OpsAllowedNets = append(cfg.OpsAllowedNets, prefix.Masked())
	}

	cfg.Documents = Documents{
		Bucket:         getenv("GCS_BUCKET"),
		BaseURL:        withDefault(getenv("GCS_BASE_URL"), "https://storage.googleapis.com"),
		ServiceAccount: Secret(getenv("GCS_SERVICE_ACCOUNT_JSON")),
		ClamAVAddr:     getenv("CLAMAV_ADDR"),
	}
	if cfg.Documents.Bucket != "" {
		if cfg.Documents.ServiceAccount == "" {
			errs = append(errs, errors.New("GCS_SERVICE_ACCOUNT_JSON is required with GCS_BUCKET"))
		}
		if cfg.Documents.ClamAVAddr == "" {
			errs = append(errs, errors.New("CLAMAV_ADDR is required with GCS_BUCKET"))
		}
	}

	cfg.Push = Push{
		ProjectID:      getenv("FCM_PROJECT_ID"),
		ServiceAccount: Secret(getenv("FCM_SERVICE_ACCOUNT_JSON")),
		BaseURL:        withDefault(getenv("FCM_BASE_URL"), "https://fcm.googleapis.com"),
		TokenURL:       withDefault(getenv("GOOGLE_TOKEN_URL"), "https://oauth2.googleapis.com/token"),
	}
	if cfg.Push.ProjectID != "" && cfg.Push.ServiceAccount == "" {
		errs = append(errs, errors.New("FCM_SERVICE_ACCOUNT_JSON is required with FCM_PROJECT_ID"))
	}

	hops, err := strconv.Atoi(withDefault(getenv("TRUSTED_PROXY_HOPS"), "0"))
	if err != nil || hops < 0 {
		errs = append(errs, errors.New("TRUSTED_PROXY_HOPS must be a non-negative integer"))
	}
	cfg.TrustedProxyHops = hops

	maxConns, err := strconv.ParseInt(withDefault(getenv("DB_MAX_CONNS"), "20"), 10, 32)
	if err != nil || maxConns < 1 {
		errs = append(errs, errors.New("DB_MAX_CONNS must be a positive integer"))
	}
	cfg.DBMaxConns = int32(maxConns) //nolint:gosec // ParseInt bounded this to 32 bits.

	cfg.DrainDelay, err = parseDuration(getenv, "SHUTDOWN_DRAIN_DELAY", "5s")
	errs = append(errs, err)
	cfg.ShutdownTimeout, err = parseDuration(getenv, "SHUTDOWN_TIMEOUT", "20s")
	errs = append(errs, err)

	if err := errors.Join(errs...); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// decodeDataKey expects standard base64 for exactly 32 random bytes.
func decodeDataKey(encoded string, errs *[]error) Secret {
	if encoded == "" {
		return ""
	}
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(key) != dataKeyBytes {
		*errs = append(*errs, fmt.Errorf("DATA_ENCRYPTION_KEY must be base64 for %d bytes", dataKeyBytes))
		return ""
	}
	return Secret(key)
}

func mpesaBaseURL(environment string) string {
	if environment == "production" {
		return "https://api.safaricom.co.ke"
	}
	return "https://sandbox.safaricom.co.ke"
}

func parseDuration(getenv func(string) string, name, fallback string) (time.Duration, error) {
	d, err := time.ParseDuration(withDefault(getenv(name), fallback))
	if err != nil || d < 0 {
		return 0, fmt.Errorf("%s must be a non-negative duration", name)
	}
	return d, nil
}

func withDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
