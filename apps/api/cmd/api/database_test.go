package main

import (
	"io"
	"testing"
)

func migrate(t *testing.T, databaseURL string) string {
	t.Helper()
	output := &capture{addr: make(chan string, 1)}
	if err := run(t.Context(), []string{"api", "migrate"}, envFor(databaseURL, ""), output, io.Discard); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	return output.String()
}
