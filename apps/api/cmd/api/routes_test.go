package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type contractRoute struct {
	method, path string
	public       bool
	stepUp       bool
	staffOnly    bool
	roles        string
}

var pathParam = regexp.MustCompile(`\{[^}]+\}`)

// contractRoutes reads every operation from the contract. Walking the contract
// means a route added later is covered without anyone remembering to add it.
func contractRoutes(t *testing.T) []contractRoute {
	t.Helper()
	data, err := os.ReadFile("../../../../packages/contract/openapi.yaml")
	if err != nil {
		t.Fatalf("read contract: %v", err)
	}
	var routes []contractRoute
	path := ""
	inPaths := false
	for line := range strings.SplitSeq(string(data), "\n") {
		switch {
		case line == "paths:":
			inPaths = true
		case strings.HasPrefix(line, "components:"):
			inPaths = false
		case !inPaths:
		case strings.HasPrefix(line, "  /") && strings.HasSuffix(line, ":"):
			path = strings.TrimSuffix(strings.TrimSpace(line), ":")
		case strings.HasPrefix(line, "    get:"), strings.HasPrefix(line, "    post:"), strings.HasPrefix(line, "    put:"):
			method := strings.ToUpper(strings.TrimSuffix(strings.TrimSpace(line), ":"))
			routes = append(routes, contractRoute{method: method, path: path})
		case strings.Contains(line, "security: []") && len(routes) > 0:
			routes[len(routes)-1].public = true
		case strings.Contains(line, "bearerAuth:") && len(routes) > 0:
			current := &routes[len(routes)-1]
			current.stepUp = strings.Contains(line, "mfa:step-up")
			current.roles = line
			current.staffOnly = (strings.Contains(line, "[ops") || strings.Contains(line, "[admin")) && !strings.Contains(line, "mfa:exempt")
		}
	}
	if len(routes) < 80 {
		t.Fatalf("parsed only %d routes, so the parser is broken", len(routes))
	}
	return routes
}

func (r contractRoute) url(base string) string {
	filled := pathParam.ReplaceAllString(r.path, "00000000-0000-4000-8000-000000000000")
	return base + filled + "?status=submitted&as=rider"
}

func TestEveryRouteDeniesByDefault(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	// The console's routes exist only with its origin set, and are walked too.
	base, _ := startServerWithEnv(t, databaseURL, provider.URL, "http://127.0.0.1:1", map[string]string{"OPS_CONSOLE_ORIGIN": consoleOrigin})
	grantStaff(t, databaseURL, "0700000001", "ops")
	grantStaff(t, databaseURL, "0700000001", "admin")
	rider, _ := signIn(t, base, stub, "0711111111", "rider")["access_token"].(string)
	driver, _ := signIn(t, base, stub, "0722222222", "driver")["access_token"].(string)
	unenrolled, _ := signIn(t, base, stub, "0700000001", "staff")["access_token"].(string)

	routes := contractRoutes(t)
	for _, route := range routes {
		if route.public {
			continue
		}
		if got := send(t, route.method, route.url(base), "", nil); got.status != http.StatusUnauthorized {
			t.Errorf("%s %s without a token = %d, want 401", route.method, route.path, got.status)
		}
		if strings.Contains(route.roles, "[") && !strings.Contains(route.roles, "[]") {
			if !strings.Contains(route.roles, "rider") {
				if got := send(t, route.method, route.url(base), rider, nil); got.status != http.StatusForbidden || got.body["code"] != "FORBIDDEN" {
					t.Errorf("%s %s as a rider = %d %v", route.method, route.path, got.status, got.body)
				}
			}
			if !strings.Contains(route.roles, "driver") {
				if got := send(t, route.method, route.url(base), driver, nil); got.status != http.StatusForbidden || got.body["code"] != "FORBIDDEN" {
					t.Errorf("%s %s as a driver = %d %v", route.method, route.path, got.status, got.body)
				}
			}
		}
		if !route.staffOnly {
			continue
		}
		if got := send(t, route.method, route.url(base), unenrolled, nil); got.status != http.StatusForbidden || got.body["code"] != "MFA_ENROLMENT_REQUIRED" {
			t.Errorf("%s %s without an authenticator = %d %v", route.method, route.path, got.status, got.body)
		}
	}

	secret := enrol(t, base, unenrolled)
	grant := stepUp(t, base, unenrolled, secret, 30*time.Second)
	for _, route := range routes {
		if !route.staffOnly {
			continue
		}
		if route.stepUp {
			if got := send(t, route.method, route.url(base), unenrolled, nil); got.status != http.StatusForbidden || got.body["code"] != "STEP_UP_REQUIRED" {
				t.Errorf("%s %s without step-up = %d %v", route.method, route.path, got.status, got.body)
			}
		}
		got := sendWithHeader(t, route.method, route.url(base), unenrolled, headerStepUp, grant, nil)
		if got.status >= http.StatusInternalServerError && got.status != http.StatusServiceUnavailable && got.status != http.StatusBadGateway {
			t.Errorf("%s %s = %d %v", route.method, route.path, got.status, got.body)
		}
	}
}
