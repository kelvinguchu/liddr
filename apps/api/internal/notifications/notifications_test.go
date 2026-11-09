package notifications_test

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
	"github.com/kelvinguchu/liddr/apps/api/internal/push"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

// firebase stands in for the network behind the real push client.
type firebase struct {
	mu   sync.Mutex
	sent []map[string]string
}

func (f *firebase) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/token" {
		_, _ = w.Write([]byte(`{"access_token":"a","expires_in":3600}`))
		return
	}
	var body struct {
		Message struct {
			Token string            `json:"token"`
			Data  map[string]string `json:"data"`
		} `json:"message"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.mu.Lock()
	defer f.mu.Unlock()
	if strings.HasPrefix(body.Message.Token, "dead") {
		w.WriteHeader(http.StatusNotFound)
		_, _ = w.Write([]byte(`{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}`))
		return
	}
	if strings.HasPrefix(body.Message.Token, "flaky") {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	f.sent = append(f.sent, body.Message.Data)
}

func (f *firebase) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sent)
}

type world struct {
	pool    *pgxpool.Pool
	service *notifications.Service
	fcm     *firebase
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), fcm: &firebase{}, now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	server := httptest.NewServer(w.fcm)
	t.Cleanup(server.Close)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	account, err := json.Marshal(map[string]string{"client_email": "x@y", "private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))})
	if err != nil {
		t.Fatalf("account: %v", err)
	}
	now := func() time.Time { return w.now }
	client, err := push.New(push.Config{BaseURL: server.URL, TokenURL: server.URL + "/token", ProjectID: "p", ServiceAccountJSON: string(account), Now: now})
	if err != nil {
		t.Fatalf("push: %v", err)
	}
	w.service = notifications.NewService(notifications.Config{Pool: w.pool, Push: client, Now: now, Logger: slog.New(slog.DiscardHandler)})
	return w
}

func (w *world) user(t *testing.T, phone string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := w.pool.Exec(t.Context(), `INSERT INTO users (id, phone) VALUES ($1, $2)`, id, phone); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	return id
}

func (w *world) notify(t *testing.T, kind string, to uuid.UUID) {
	t.Helper()
	ride := uuid.New()
	if err := events.Notify(t.Context(), store.New(w.pool), events.Event{Type: kind, RideID: &ride, Status: "accepted"}, to); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if _, err := w.pool.Exec(t.Context(), `UPDATE notifications SET created_at = $1 WHERE created_at > $1`, w.now); err != nil {
		t.Fatalf("set time: %v", err)
	}
}

func (w *world) pushStatus(t *testing.T) string {
	t.Helper()
	var status string
	if err := w.pool.QueryRow(t.Context(), `SELECT push_status FROM notifications`).Scan(&status); err != nil {
		t.Fatalf("read status: %v", err)
	}
	return status
}

func (w *world) register(t *testing.T, user uuid.UUID, token string) {
	t.Helper()
	if err := w.service.RegisterDevice(t.Context(), notifications.Device{UserID: user, FamilyID: uuid.New(), Token: token, Platform: "android"}); err != nil {
		t.Fatalf("RegisterDevice: %v", err)
	}
}

func TestPushDelivery(t *testing.T) {
	cases := []struct {
		name   string
		tokens []string
		want   string
		sends  int
	}{
		{"delivered", []string{"good-token-1"}, "sent", 1},
		{"no device", nil, "no_device", 0},
		{"one dead one good", []string{"dead-token-1", "good-token-1"}, "sent", 1},
		{"only dead", []string{"dead-token-1"}, "no_device", 0},
		{"provider down stays pending", []string{"flaky-token"}, "pending", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			user := w.user(t, "254711111111")
			for _, token := range tc.tokens {
				w.register(t, user, token)
			}
			w.notify(t, events.TypeRideStatus, user)
			if err := w.service.DeliverPending(t.Context()); err != nil {
				t.Fatalf("DeliverPending: %v", err)
			}
			if got := w.pushStatus(t); got != tc.want {
				t.Errorf("status = %s, want %s", got, tc.want)
			}
			if got := w.fcm.count(); got != tc.sends {
				t.Errorf("sends = %d, want %d", got, tc.sends)
			}
		})
	}
}

func TestStaleOfferIsNotPushed(t *testing.T) {
	w := newWorld(t)
	user := w.user(t, "254711111111")
	w.register(t, user, "good-token-1")
	w.notify(t, events.TypeOfferCreated, user)
	w.now = w.now.Add(21 * time.Second)
	if err := w.service.DeliverPending(t.Context()); err != nil {
		t.Fatalf("DeliverPending: %v", err)
	}
	if got := w.pushStatus(t); got != "expired" || w.fcm.count() != 0 {
		t.Errorf("status = %s, sends = %d", got, w.fcm.count())
	}
}

func TestProviderFailureGivesUpAfterRetries(t *testing.T) {
	w := newWorld(t)
	user := w.user(t, "254711111111")
	w.register(t, user, "flaky-token")
	w.notify(t, events.TypeRideStatus, user)
	for range 5 {
		if err := w.service.DeliverPending(t.Context()); err != nil {
			t.Fatalf("DeliverPending: %v", err)
		}
		w.now = w.now.Add(61 * time.Second)
	}
	if got := w.pushStatus(t); got != "failed" {
		t.Errorf("status = %s, want failed", got)
	}
}

func TestPushCarriesIdentifiersOnly(t *testing.T) {
	w := newWorld(t)
	user := w.user(t, "254711111111")
	w.register(t, user, "good-token-1")
	w.notify(t, events.TypeRideStatus, user)
	if err := w.service.DeliverPending(t.Context()); err != nil {
		t.Fatalf("DeliverPending: %v", err)
	}
	allowed := map[string]bool{"notification_id": true, "event_type": true, "ride_id": true, "offer_id": true, "status": true}
	for key := range w.fcm.sent[0] {
		if !allowed[key] {
			t.Errorf("push carried %q", key)
		}
	}
}
