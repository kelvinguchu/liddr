package auth_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"regexp"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/sealing"
	"github.com/kelvinguchu/liddr/apps/api/internal/sms"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

const testPhone = "254712345678"

var codePattern = regexp.MustCompile(`code is: (\d{6})`)

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// provider is an httptest stand-in for HostPinnacle, driven by the real client.
type provider struct {
	mu   sync.Mutex
	code string
	sent atomic.Int32
	down atomic.Bool
}

func (p *provider) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if p.down.Load() {
		http.Error(w, "unavailable", http.StatusBadGateway)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad form", http.StatusBadRequest)
		return
	}
	if match := codePattern.FindStringSubmatch(r.PostForm.Get("msg")); match != nil {
		p.mu.Lock()
		p.code = match[1]
		p.mu.Unlock()
	}
	p.sent.Add(1)
	_, _ = w.Write([]byte(`{"status":"success"}`))
}

func (p *provider) lastCode() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.code
}

type harness struct {
	svc      *auth.Service
	pool     *pgxpool.Pool
	clock    *clock
	provider *provider
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pool := testdb.Pool(t)
	stub := &provider{}
	server := httptest.NewServer(stub)
	t.Cleanup(server.Close)
	c := &clock{now: time.Date(2026, 11, 9, 8, 0, 0, 0, time.UTC)}
	box, err := sealing.New(bytes.Repeat([]byte{1}, sealing.KeyBytes))
	if err != nil {
		t.Fatalf("sealing: %v", err)
	}
	return &harness{
		svc: auth.NewService(auth.Config{
			Pool:    pool,
			SMS:     sms.NewClient(sms.Config{URL: server.URL}),
			HMACKey: []byte("test-key-of-sufficient-length-for-hmac"),
			Box:     box,
			Now:     c.Now,
		}),
		pool:     pool,
		clock:    c,
		provider: stub,
	}
}

func testMeta() auth.RequestMeta {
	return auth.RequestMeta{IP: netip.MustParseAddr("203.0.113.7"), RequestID: "test-request"}
}

func request(t *testing.T, h *harness, phone string, role auth.Role) auth.Challenge {
	t.Helper()
	challenge, err := h.svc.RequestOTP(t.Context(), auth.OTPRequest{Phone: phone, Role: role, Meta: testMeta()})
	if err != nil {
		t.Fatalf("RequestOTP: %v", err)
	}
	return challenge
}

func signIn(t *testing.T, h *harness, phone string, role auth.Role) auth.Tokens {
	t.Helper()
	challenge := request(t, h, phone, role)
	tokens, err := h.svc.VerifyOTP(t.Context(), challenge.ID, h.provider.lastCode(), testMeta())
	if err != nil {
		t.Fatalf("VerifyOTP: %v", err)
	}
	return tokens
}

// wrongCode returns a well-formed code that differs from the one sent.
func wrongCode(h *harness) string {
	if h.provider.lastCode() == "000000" {
		return "000001"
	}
	return "000000"
}

func setAccountStatus(t *testing.T, h *harness, userID uuid.UUID, status string) {
	t.Helper()
	if _, err := h.pool.Exec(t.Context(), `UPDATE users SET account_status = $1 WHERE id = $2`, status, userID); err != nil {
		t.Fatalf("set account status: %v", err)
	}
}

func auditCount(t *testing.T, h *harness, action string) int {
	t.Helper()
	var count int
	if err := h.pool.QueryRow(t.Context(), `SELECT count(*) FROM audit_events WHERE action = $1`, action).Scan(&count); err != nil {
		t.Fatalf("count audit events: %v", err)
	}
	return count
}
