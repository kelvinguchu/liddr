package httpapi

import (
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

func TestHasAllowedRole(t *testing.T) {
	tests := []struct {
		name    string
		held    []auth.Role
		allowed []string
		want    bool
	}{
		{"any account", []auth.Role{auth.RoleRider}, nil, true},
		{"any account with no roles", nil, nil, true},
		{"matching role", []auth.Role{auth.RoleDriver}, []string{"driver"}, true},
		{"one of several", []auth.Role{auth.RoleOps}, []string{"admin", "ops"}, true},
		{"wrong role", []auth.Role{auth.RoleRider}, []string{"driver"}, false},
		{"no roles", nil, []string{"driver"}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := hasAllowedRole(tt.held, tt.allowed); got != tt.want {
				t.Errorf("hasAllowedRole = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestBearerToken(t *testing.T) {
	tests := map[string]string{
		"":               "",
		"Bearer abc":     "abc",
		"bearer abc":     "abc",
		"Bearer   abc  ": "abc",
		"Bearer":         "",
		"Basic dXNlcjpw": "",
		"abc":            "",
	}
	for header, want := range tests {
		t.Run(header, func(t *testing.T) {
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
			if header != "" {
				r.Header.Set("Authorization", header)
			}
			if got := bearerToken(r); got != want {
				t.Errorf("bearerToken = %q, want %q", got, want)
			}
		})
	}
}

func TestClientAddressIgnoresForgedEntries(t *testing.T) {
	const remote = "10.0.0.5:4000"
	tests := []struct {
		name    string
		hops    int
		forward []string
		want    string
	}{
		{"direct ignores header", 0, []string{"1.1.1.1"}, "10.0.0.5"},
		{"one proxy", 1, []string{"203.0.113.9"}, "203.0.113.9"},
		{"one proxy with forged prefix", 1, []string{"1.1.1.1, 203.0.113.9"}, "203.0.113.9"},
		{"two proxies", 2, []string{"1.1.1.1, 203.0.113.9, 35.191.0.1"}, "203.0.113.9"},
		{"split across headers", 1, []string{"1.1.1.1", "203.0.113.9"}, "203.0.113.9"},
		{"fewer entries than hops", 2, []string{"203.0.113.9"}, "10.0.0.5"},
		{"garbage entry", 1, []string{"not-an-ip"}, "10.0.0.5"},
		{"mapped ipv4", 1, []string{"::ffff:203.0.113.9"}, "203.0.113.9"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
			r.RemoteAddr = remote
			for _, value := range tt.forward {
				r.Header.Add("X-Forwarded-For", value)
			}
			if got := clientAddress(r, tt.hops); got != netip.MustParseAddr(tt.want) {
				t.Errorf("clientAddress = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestRoutesRequireAuth guards the generator setting that carries each route's
// security rule. If it is lost, protected routes silently become public.
func TestRoutesRequireAuth(t *testing.T) {
	a := newTestAPI(stubPinger{})
	rec := httptest.NewRecorder()
	a.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/v1/me", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("GET /v1/me without a token = %d, want 401", rec.Code)
	}
}
