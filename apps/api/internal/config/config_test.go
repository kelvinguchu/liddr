package config

import (
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/google/go-cmp/cmp"
)

func env(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestLoadAppliesDefaults(t *testing.T) {
	got, err := Load(env(map[string]string{"DATABASE_URL": "postgres://db"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := Config{
		Addr:            ":8080",
		DatabaseURL:     "postgres://db",
		DBMaxConns:      20,
		DrainDelay:      5 * time.Second,
		ShutdownTimeout: 20 * time.Second,
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("config mismatch (-got +want):\n%s", diff)
	}
}

func TestLoadRejectsInvalidValues(t *testing.T) {
	const url = "postgres://user:hunter2@db" //nolint:gosec // Fake credential that proves errors redact it.
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{"missing database url", map[string]string{}, "DATABASE_URL is required"},
		{"non-numeric pool", map[string]string{"DATABASE_URL": url, "DB_MAX_CONNS": "many"}, "DB_MAX_CONNS"},
		{"zero pool", map[string]string{"DATABASE_URL": url, "DB_MAX_CONNS": "0"}, "DB_MAX_CONNS"},
		{"pool beyond 32 bits", map[string]string{"DATABASE_URL": url, "DB_MAX_CONNS": "9999999999"}, "DB_MAX_CONNS"},
		{"bad drain", map[string]string{"DATABASE_URL": url, "SHUTDOWN_DRAIN_DELAY": "soon"}, "SHUTDOWN_DRAIN_DELAY"},
		{"negative timeout", map[string]string{"DATABASE_URL": url, "SHUTDOWN_TIMEOUT": "-1s"}, "SHUTDOWN_TIMEOUT"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Load(env(tt.env))
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
