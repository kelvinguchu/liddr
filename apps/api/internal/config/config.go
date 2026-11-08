// Package config reads process configuration from the environment.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
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

const minHMACKeyBytes = 32

// SMS holds HostPinnacle credentials.
type SMS struct {
	URL      string
	APIKey   Secret
	UserID   string
	Password Secret
	SenderID string
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
	SMS              SMS
	GoogleMapsKey    Secret
	GoogleRoutesURL  string
}

// LoadDatabaseURL returns the only setting that migrations need.
func LoadDatabaseURL(getenv func(string) string) (Secret, error) {
	url := Secret(getenv("DATABASE_URL"))
	if url == "" {
		return "", errors.New("DATABASE_URL is required")
	}
	return url, nil
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
	if cfg.AuthHMACKey != "" && len(cfg.AuthHMACKey) < minHMACKeyBytes {
		errs = append(errs, fmt.Errorf("AUTH_HMAC_KEY must be at least %d bytes", minHMACKeyBytes))
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
