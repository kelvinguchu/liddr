package main

import (
	"io"
	"net/http"
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

func get(t *testing.T, target string) (int, http.Header, []byte) {
	t.Helper()
	client := http.Client{Timeout: testTimeout, Transport: &http.Transport{DisableKeepAlives: true}}
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, target, nil)
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", target, err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Errorf("close body: %v", err)
		}
	}()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return resp.StatusCode, resp.Header, body
}
