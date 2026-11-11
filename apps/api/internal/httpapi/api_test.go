package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type stubPinger struct{ err error }

func (s stubPinger) Ping(context.Context) error { return s.err }

func newTestAPI(db Pinger) *API {
	return New(Deps{Logger: slog.New(slog.DiscardHandler), Database: db})
}

func getStatus(t *testing.T, a *API, path string) int {
	t.Helper()
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, path, nil))
	return rec.Code
}

func TestReadiness(t *testing.T) {
	tests := []struct {
		name  string
		err   error
		drain bool
		want  int
	}{
		{name: "database reachable", want: http.StatusOK},
		{name: "database unreachable", err: errors.New("connection refused"), want: http.StatusServiceUnavailable},
		{name: "draining with database reachable", drain: true, want: http.StatusServiceUnavailable},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := newTestAPI(stubPinger{err: tt.err})
			if tt.drain {
				a.BeginDrain()
			}
			if got := getStatus(t, a, "/readyz"); got != tt.want {
				t.Errorf("GET /readyz = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestLivenessIgnoresDrainAndDatabase(t *testing.T) {
	a := newTestAPI(stubPinger{err: errors.New("down")})
	a.BeginDrain()
	if got := getStatus(t, a, "/healthz"); got != http.StatusOK {
		t.Errorf("GET /healthz = %d, want 200", got)
	}
}

func TestPanicBecomesSafeError(t *testing.T) {
	a := newTestAPI(stubPinger{})
	h := a.withMiddleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("phone number 0712345678")
	}))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil))

	if rec.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "0712345678") {
		t.Errorf("response leaked the panic value: %s", rec.Body)
	}
	var body Error
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	if body.Code != "INTERNAL_ERROR" {
		t.Errorf("code = %q, want INTERNAL_ERROR", body.Code)
	}
	if got, want := body.RequestId, rec.Header().Get("X-Request-Id"); got == "" || got != want {
		t.Errorf("request_id = %q, want header value %q", got, want)
	}
}

func TestAbortPanicIsNotSwallowed(t *testing.T) {
	a := newTestAPI(stubPinger{})
	h := a.withMiddleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic(http.ErrAbortHandler)
	}))
	defer func() {
		got, _ := recover().(error)
		if !errors.Is(got, http.ErrAbortHandler) {
			t.Errorf("recovered %v, want http.ErrAbortHandler", got)
		}
	}()
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil))
}

func TestRequestLimits(t *testing.T) {
	a := newTestAPI(stubPinger{})
	var readErr error
	var hasDeadline bool
	h := a.withMiddleware(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		_, hasDeadline = r.Context().Deadline()
		_, readErr = io.ReadAll(r.Body)
	}))

	body := strings.NewReader(strings.Repeat("x", maxBodyBytes+1))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodPost, "/", body))

	if !hasDeadline {
		t.Error("handler context has no deadline")
	}
	if _, ok := errors.AsType[*http.MaxBytesError](readErr); !ok {
		t.Errorf("read error = %v, want *http.MaxBytesError", readErr)
	}
}

func TestResponseHeaders(t *testing.T) {
	a := newTestAPI(stubPinger{})
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/healthz", nil))

	for name, want := range map[string]string{
		"X-Content-Type-Options": "nosniff",
		"Cache-Control":          "no-store",
	} {
		if got := rec.Header().Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if rec.Header().Get("X-Request-Id") == "" {
		t.Error("X-Request-Id is missing")
	}
}
