package httpapi

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"runtime/debug"
	"time"
)

const (
	maxBodyBytes = 1 << 20

	// RequestTimeout stays below the server's WriteTimeout so handlers can
	// still send an error response.
	RequestTimeout = 20 * time.Second
)

type requestInfoKey struct{}

type requestInfo struct {
	id string
	ip netip.Addr
}

func requestInfoFrom(ctx context.Context) requestInfo {
	info, _ := ctx.Value(requestInfoKey{}).(requestInfo)
	return info
}

func requestID(ctx context.Context) string {
	return requestInfoFrom(ctx).id
}

// withMiddleware applies request limits, response headers, panic recovery and
// access logging. r is replaced only once, before next runs, so r.Pattern set
// by the mux is visible here afterwards.
func (a *API) withMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := rand.Text()
		ctx, cancel := context.WithTimeout(r.Context(), RequestTimeout)
		defer cancel()
		info := requestInfo{id: id, ip: clientAddress(r, a.deps.TrustedProxyHops)}
		r = r.WithContext(context.WithValue(ctx, requestInfoKey{}, info))
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)

		headers := w.Header()
		headers.Set("X-Request-Id", id)
		headers.Set("X-Content-Type-Options", "nosniff")
		headers.Set("Cache-Control", "no-store")

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		defer func() {
			if p := recover(); p != nil {
				if err, ok := p.(error); ok && errors.Is(err, http.ErrAbortHandler) {
					panic(p) //nolint:forbidigo // net/http uses this panic to abort the response.
				}
				a.logPanic(r, p)
				if !rec.wroteHeader {
					writeError(rec, r, http.StatusInternalServerError, "INTERNAL_ERROR", "Something went wrong. Please try again.")
				}
			}
			a.logAccess(r, rec.status, time.Since(start))
		}()
		next.ServeHTTP(rec, r)
	})
}

// logPanic records the panic's type and stack. The value itself is left out
// because it can hold request data.
func (a *API) logPanic(r *http.Request, p any) {
	a.deps.Logger.LogAttrs(r.Context(), slog.LevelError, "panic serving request",
		slog.String("request_id", requestID(r.Context())),
		slog.String("route", r.Pattern),
		slog.String("panic_type", fmt.Sprintf("%T", p)),
		slog.String("stack", string(debug.Stack())),
	)
}

// logAccess uses the route pattern, not the URL, so paths holding identifiers
// stay out of logs. Successful probes are skipped as noise.
func (a *API) logAccess(r *http.Request, status int, elapsed time.Duration) {
	if status < http.StatusBadRequest && isProbe(r.Pattern) {
		return
	}
	a.deps.Logger.LogAttrs(r.Context(), slog.LevelInfo, "http request",
		slog.String("request_id", requestID(r.Context())),
		slog.String("method", r.Method),
		slog.String("route", r.Pattern),
		slog.Int("status", status),
		slog.Int64("duration_ms", elapsed.Milliseconds()),
	)
}

func isProbe(pattern string) bool {
	return pattern == "GET /healthz" || pattern == "GET /readyz"
}

type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (s *statusRecorder) WriteHeader(status int) {
	if !s.wroteHeader {
		s.status = status
		s.wroteHeader = true
	}
	s.ResponseWriter.WriteHeader(status)
}

func (s *statusRecorder) Write(p []byte) (int, error) {
	s.wroteHeader = true
	return s.ResponseWriter.Write(p)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (s *statusRecorder) Unwrap() http.ResponseWriter {
	return s.ResponseWriter
}
