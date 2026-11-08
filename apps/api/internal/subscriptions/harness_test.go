package subscriptions_test

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

const callbackToken = "callback-token-of-sufficient-length-for-tests"

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *clock) Set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = t
}

func (c *clock) Advance(d time.Duration) { c.Set(c.Now().Add(d)) }

// daraja stands in for Safaricom, the only third-party network here.
type daraja struct {
	mu          sync.Mutex
	stkStatus   int
	stkBody     string
	queryStatus int
	queryBody   string
	lastAmount  float64
	lastPhone   string
	stkCalls    atomic.Int32
	counter     atomic.Int32
}

func (d *daraja) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case strings.HasPrefix(r.URL.Path, "/oauth"):
		_, _ = w.Write([]byte(`{"access_token":"tok"}`))
	case strings.Contains(r.URL.Path, "stkpushquery"):
		w.WriteHeader(d.queryStatus)
		_, _ = w.Write([]byte(d.queryBody))
	case strings.Contains(r.URL.Path, "stkpush"):
		var body struct {
			Amount float64
			PartyA string
		}
		_ = json.NewDecoder(r.Body).Decode(&body) // Tests assert on what was parsed.
		d.lastAmount, d.lastPhone = body.Amount, body.PartyA
		d.stkCalls.Add(1)
		w.WriteHeader(d.stkStatus)
		reply := d.stkBody
		if reply == "" {
			reply = fmt.Sprintf(`{"ResponseCode":"0","MerchantRequestID":"m","CheckoutRequestID":"ws_%d"}`, d.counter.Add(1))
		}
		_, _ = w.Write([]byte(reply))
	default:
		http.NotFound(w, r)
	}
}

func (d *daraja) setSTK(status int, body string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stkStatus, d.stkBody = status, body
}

func (d *daraja) setQuery(status int, body string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.queryStatus, d.queryBody = status, body
}

type harness struct {
	svc       *subscriptions.Service
	pool      *pgxpool.Pool
	clock     *clock
	daraja    *daraja
	nextPhone atomic.Int64
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	pool := testdb.Pool(t)
	stub := &daraja{stkStatus: 200, queryStatus: 200, queryBody: `{"ResultCode":"4999"}`}
	server := httptest.NewServer(stub)
	t.Cleanup(server.Close)

	// Monday 12:00 in Nairobi.
	c := &clock{now: time.Date(2026, 11, 9, 9, 0, 0, 0, time.UTC)}
	return &harness{
		svc: subscriptions.NewService(subscriptions.Config{
			Pool:            pool,
			Gateway:         payments.NewClient(payments.Config{BaseURL: server.URL, Shortcode: "174379", Passkey: "p"}, c.Now),
			Now:             c.Now,
			Logger:          slog.New(slog.DiscardHandler),
			CallbackBaseURL: "https://api.example",
			CallbackToken:   callbackToken,
			Shortcode:       "174379",
		}),
		pool:   pool,
		clock:  c,
		daraja: stub,
	}
}

func (h *harness) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := h.pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

func phoneOf(n int64) string { return fmt.Sprintf("25470%07d", n) }

// newDriver creates an approved motorbike driver and returns the ID and phone.
func (h *harness) newDriver(t *testing.T, verification string) (uuid.UUID, string) {
	t.Helper()
	phone := phoneOf(h.nextPhone.Add(1))
	var id uuid.UUID
	if err := h.pool.QueryRow(t.Context(), `INSERT INTO users (phone) VALUES ($1) RETURNING id`, phone).Scan(&id); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	h.exec(t, `INSERT INTO drivers (user_id, vehicle_category_id, verification_status)
		SELECT $1, id, $2 FROM vehicle_categories WHERE slug = 'motorbike'`, id, verification)
	return id, phone
}

func stkBody(checkout string, code int, amount any, phone string) []byte {
	metadata := ""
	if code == 0 {
		metadata = fmt.Sprintf(`,"CallbackMetadata":{"Item":[{"Name":"Amount","Value":%v},{"Name":"MpesaReceiptNumber","Value":"R%s"},{"Name":"PhoneNumber","Value":%q}]}`, amount, checkout, phone)
	}
	return fmt.Appendf(nil, `{"Body":{"stkCallback":{"MerchantRequestID":"m","CheckoutRequestID":%q,"ResultCode":%d,"ResultDesc":"d"%s}}}`, checkout, code, metadata)
}

func c2bBody(transaction, reference string, amount any) []byte {
	return fmt.Appendf(nil, `{"TransID":%q,"TransAmount":"%v","BillRefNumber":%q,"MSISDN":"254799999999"}`, transaction, amount, reference)
}

func (h *harness) pay(t *testing.T, driver uuid.UUID) subscriptions.Payment {
	t.Helper()
	payment, err := h.svc.Pay(t.Context(), driver)
	if err != nil {
		t.Fatalf("Pay: %v", err)
	}
	return payment
}

func (h *harness) handleSTK(t *testing.T, body []byte) {
	t.Helper()
	if err := h.svc.HandleSTK(t.Context(), body); err != nil {
		t.Fatalf("HandleSTK: %v", err)
	}
}

func (h *harness) handleC2B(t *testing.T, body []byte) {
	t.Helper()
	if err := h.svc.HandleC2B(t.Context(), body); err != nil {
		t.Fatalf("HandleC2B: %v", err)
	}
}

func (h *harness) reference(t *testing.T, driver uuid.UUID) string {
	t.Helper()
	summary, err := h.svc.Current(t.Context(), driver)
	if err != nil {
		t.Fatalf("Current: %v", err)
	}
	return summary.Reference
}

func (h *harness) scalar(t *testing.T, sql string, args ...any) string {
	t.Helper()
	var value string
	if err := h.pool.QueryRow(t.Context(), sql, args...).Scan(&value); err != nil {
		t.Fatalf("query %q: %v", sql, err)
	}
	return value
}

func (h *harness) driverStatus(t *testing.T, driver uuid.UUID) string {
	t.Helper()
	return h.scalar(t, `SELECT subscription_status FROM drivers WHERE user_id = $1`, driver)
}

func (h *harness) paymentStatus(t *testing.T, id uuid.UUID) string {
	t.Helper()
	return h.scalar(t, `SELECT status FROM subscription_payments WHERE id = $1`, id)
}

func (h *harness) activeWeeks(t *testing.T, driver uuid.UUID) string {
	t.Helper()
	return h.scalar(t, `SELECT count(*)::text FROM subscriptions WHERE driver_id = $1 AND status = 'active'`, driver)
}
