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

// Config is the validated process configuration.
type Config struct {
	Addr            string
	DatabaseURL     Secret
	DBMaxConns      int32
	DrainDelay      time.Duration
	ShutdownTimeout time.Duration
}

// Load validates the environment and reports every problem at once. Errors
// name the variable and never include its value.
func Load(getenv func(string) string) (Config, error) {
	var errs []error

	cfg := Config{
		Addr:        withDefault(getenv("ADDR"), ":8080"),
		DatabaseURL: Secret(getenv("DATABASE_URL")),
	}
	if cfg.DatabaseURL == "" {
		errs = append(errs, errors.New("DATABASE_URL is required"))
	}

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
