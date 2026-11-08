package main

import (
	"context"
	"crypto/rand"
	"io"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// testDatabase creates a database owned by this test and drops it afterwards.
func testDatabase(t *testing.T) string {
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
		ctx, cancel := context.WithTimeout(context.WithoutCancel(t.Context()), testTimeout)
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

func migrate(t *testing.T, databaseURL string) string {
	t.Helper()
	output := &capture{addr: make(chan string, 1)}
	if err := run(t.Context(), []string{"api", "migrate"}, envFor(databaseURL), output, io.Discard); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return output.String()
}
