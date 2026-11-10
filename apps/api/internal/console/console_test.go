package console

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func serve(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
	return rec
}

func TestConsoleServesItsFilesSafely(t *testing.T) {
	h, err := Handler(Config{DocumentOrigin: "https://storage.googleapis.com/some/path"})
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	tests := []struct {
		name   string
		path   string
		status int
		kind   string
	}{
		{name: "the page", path: "/ops/", status: http.StatusOK, kind: "text/html"},
		{name: "a script", path: "/ops/js/app.js", status: http.StatusOK, kind: "text/javascript"},
		{name: "the stylesheet", path: "/ops/app.css", status: http.StatusOK, kind: "text/css"},
		{name: "no directory listing", path: "/ops/js/", status: http.StatusNotFound},
		{name: "no escaping the folder", path: "/ops/../console.go", status: http.StatusNotFound},
		{name: "unknown file", path: "/ops/missing.js", status: http.StatusNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := serve(t, h, tt.path)
			if rec.Code != tt.status {
				t.Fatalf("GET %s = %d, want %d", tt.path, rec.Code, tt.status)
			}
			if tt.kind != "" && !strings.HasPrefix(rec.Header().Get("Content-Type"), tt.kind) {
				t.Errorf("Content-Type = %q, want %s", rec.Header().Get("Content-Type"), tt.kind)
			}
		})
	}
	rec := serve(t, h, "/ops/")
	policy := rec.Header().Get("Content-Security-Policy")
	for _, want := range []string{"default-src 'none'", "script-src 'self'", "img-src 'self' https://storage.googleapis.com;", "frame-ancestors 'none'", "connect-src 'self'"} {
		if !strings.Contains(policy, want) {
			t.Errorf("policy %q lacks %q", policy, want)
		}
	}
	if strings.Contains(policy, "unsafe-inline") || strings.Contains(policy, "unsafe-eval") {
		t.Errorf("policy allows inline code: %q", policy)
	}
	if rec.Header().Get("X-Frame-Options") != "DENY" || rec.Header().Get("Referrer-Policy") != "no-referrer" || rec.Header().Get("Cache-Control") != "no-cache" {
		t.Errorf("headers = %v", rec.Header())
	}
}

func TestConsoleRefusesABadDocumentOrigin(t *testing.T) {
	for _, origin := range []string{"javascript:alert(1)", "storage.googleapis.com", "ftp://x"} {
		if _, err := Handler(Config{DocumentOrigin: origin}); err == nil {
			t.Errorf("Handler accepted %q", origin)
		}
	}
}

func TestPageLoadsNoInlineCode(t *testing.T) {
	h, err := Handler(Config{})
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	page := serve(t, h, "/ops/").Body.String()
	for _, inline := range []string{"<script>", " style=", " onclick=", " onload="} {
		if strings.Contains(page, inline) {
			t.Errorf("index.html contains %q, which the policy blocks", inline)
		}
	}
}
