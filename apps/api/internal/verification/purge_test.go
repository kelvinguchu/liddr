package verification

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
)

// bucket stands in for Cloud Storage.
type bucket struct {
	mu      sync.Mutex
	deleted []string
	status  int
}

func (b *bucket) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if r.Method == http.MethodDelete {
		b.deleted = append(b.deleted, r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:])
	}
	w.WriteHeader(b.status)
}

func (b *bucket) count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.deleted)
}

func storageFor(t *testing.T, w *world, b *bucket) *storage.Client {
	t.Helper()
	server := httptest.NewServer(b)
	t.Cleanup(server.Close)
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	account, err := json.Marshal(map[string]string{
		"client_email": "signer@example.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	})
	if err != nil {
		t.Fatalf("marshal account: %v", err)
	}
	client, err := storage.New(storage.Config{BaseURL: server.URL, Bucket: "b", ServiceAccountJSON: string(account), Now: func() time.Time { return w.now }})
	if err != nil {
		t.Fatalf("storage.New: %v", err)
	}
	return client
}

func (w *world) storedDocument(t *testing.T, driverID, applicationID uuid.UUID, kind string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	w.exec(t, `INSERT INTO verification_documents (id, application_id, driver_id, document_type, version, status,
		storage_key, content_type, size_bytes, scan_status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, 1, 'validated', $5, 'image/jpeg', 1, 'clean', now(), now())`, id, applicationID, driverID, kind, id.String())
	return id
}

func (w *world) purged(t *testing.T, id uuid.UUID) bool {
	t.Helper()
	var purged bool
	if err := w.pool.QueryRow(t.Context(), `SELECT purged_at IS NOT NULL FROM verification_documents WHERE id = $1`, id).Scan(&purged); err != nil {
		t.Fatalf("read document: %v", err)
	}
	return purged
}

func TestPurgeRemovesFilesOnlyOnceTheirTimeIsUp(t *testing.T) {
	const day = 24 * time.Hour
	tests := []struct {
		name       string
		closedAgo  time.Duration
		kind       string
		docStatus  string
		appStatus  string
		status     int
		wantDelete int
		wantPurged bool
		wantErr    bool
	}{
		{name: "closed over a year ago", closedAgo: 366 * day, kind: "drivers_licence", status: http.StatusNoContent, wantDelete: 1, wantPurged: true},
		{name: "already gone from storage", closedAgo: 366 * day, kind: "drivers_licence", status: http.StatusNotFound, wantDelete: 1, wantPurged: true},
		{name: "storage failure is retried", closedAgo: 366 * day, kind: "drivers_licence", status: http.StatusServiceUnavailable, wantDelete: 1, wantErr: true},
		{name: "closed under a year ago", closedAgo: 364 * day, kind: "drivers_licence", status: http.StatusNoContent},
		{name: "selfie in use stays", kind: "driver_selfie_liveness", status: http.StatusNoContent},
		{name: "selfie goes 30 days after closure", closedAgo: 31 * day, kind: "driver_selfie_liveness", status: http.StatusNoContent, wantDelete: 1, wantPurged: true},
		{name: "licence stays 31 days after closure", closedAgo: 31 * day, kind: "drivers_licence", status: http.StatusNoContent},
		{name: "selfie stays 29 days after closure", closedAgo: 29 * day, kind: "driver_selfie_liveness", status: http.StatusNoContent},
		{name: "replaced selfie goes", kind: "driver_selfie_liveness", docStatus: "superseded", status: http.StatusNoContent, wantDelete: 1, wantPurged: true},
		{name: "rejected selfie goes", kind: "driver_selfie_liveness", docStatus: "rejected", status: http.StatusNoContent, wantDelete: 1, wantPurged: true},
		{name: "selfie from a rejected application goes", kind: "driver_selfie_liveness", appStatus: "rejected", status: http.StatusNoContent, wantDelete: 1, wantPurged: true},
		{name: "rejected licence stays", kind: "drivers_licence", docStatus: "rejected", status: http.StatusNoContent},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			b := &bucket{status: tt.status}
			w.service = NewService(Config{Pool: w.pool, Storage: storageFor(t, w, b), Now: func() time.Time { return w.now }})
			driver, application := w.approvedDriver(t, "254700000001")
			document := w.storedDocument(t, driver, application, tt.kind)
			w.exec(t, `UPDATE verification_applications SET decided_at = $2 WHERE id = $1`, application, w.now.Add(-400*day))
			w.exec(t, `UPDATE verification_documents SET updated_at = $2 WHERE id = $1`, document, w.now.Add(-400*day))
			if tt.docStatus != "" {
				w.exec(t, `UPDATE verification_documents SET status = $2 WHERE id = $1`, document, tt.docStatus)
			}
			if tt.appStatus != "" {
				w.exec(t, `UPDATE verification_applications SET status = $2 WHERE id = $1`, application, tt.appStatus)
			}
			if tt.closedAgo > 0 {
				w.exec(t, `UPDATE users SET deleted_at = $2 WHERE id = $1`, driver, w.now.Add(-tt.closedAgo))
			}
			err := w.service.PurgeDocuments(t.Context())
			if (err != nil) != tt.wantErr {
				t.Fatalf("PurgeDocuments = %v, wantErr %v", err, tt.wantErr)
			}
			if got := b.count(); got != tt.wantDelete {
				t.Errorf("deletes = %d, want %d", got, tt.wantDelete)
			}
			if got := w.purged(t, document); got != tt.wantPurged {
				t.Errorf("purged = %v, want %v", got, tt.wantPurged)
			}
		})
	}
}

func TestPurgedDocumentCannotBeDownloaded(t *testing.T) {
	w := newWorld(t)
	b := &bucket{status: http.StatusNoContent}
	w.service = NewService(Config{Pool: w.pool, Storage: storageFor(t, w, b), Now: func() time.Time { return w.now }})
	driver, application := w.approvedDriver(t, "254700000001")
	document := w.storedDocument(t, driver, application, "drivers_licence")
	w.exec(t, `UPDATE verification_documents SET purged_at = now() WHERE id = $1`, document)
	_, _, err := w.service.DownloadURL(t.Context(), document, Actor{UserID: uuid.New(), RequestID: "r"})
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("DownloadURL = %v, want ErrNotFound", err)
	}
}
