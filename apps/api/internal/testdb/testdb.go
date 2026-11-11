// Package testdb gives integration tests a private, migrated Postgres database.
package testdb

import (
	"context"
	"crypto/rand"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const cleanupTimeout = 30 * time.Second

// URL creates an empty database owned by this test and drops it afterwards.
// It fails in CI when TEST_DATABASE_URL is unset and skips locally.
func URL(t *testing.T) string {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		if os.Getenv("CI") != "" {
			t.Fatal("TEST_DATABASE_URL must be set in CI")
		}
		t.Skip("TEST_DATABASE_URL is not set")
	}
	parsed, err := url.Parse(base)
	if err != nil {
		t.Fatal("TEST_DATABASE_URL is not a valid URL")
	}

	name := "liddr_test_" + strings.ToLower(rand.Text())
	admin, err := pgx.Connect(t.Context(), base)
	if err != nil {
		t.Fatalf("connect to test server: %v", err)
	}
	identifier := pgx.Identifier{name}.Sanitize()
	if _, err := admin.Exec(t.Context(), "CREATE DATABASE "+identifier); err != nil {
		t.Fatalf("create test database: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(t.Context()), cleanupTimeout)
		defer cancel()
		if _, err := admin.Exec(ctx, "DROP DATABASE "+identifier+" WITH (FORCE)"); err != nil {
			t.Errorf("drop test database: %v", err)
		}
		if err := admin.Close(ctx); err != nil {
			t.Errorf("close admin connection: %v", err)
		}
	})
	parsed.Path = "/" + name
	return parsed.String()
}

// Pool returns a connection pool on a private database with migrations applied.
func Pool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	databaseURL := URL(t)
	if _, err := store.Migrate(t.Context(), databaseURL); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := store.OpenPool(t.Context(), databaseURL, 16)
	if err != nil {
		t.Fatalf("open pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}
