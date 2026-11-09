package dispatch_test

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
)

// signingClient signs links locally. Nothing here reaches a network.
func signingClient(t *testing.T, h *harness) *storage.Client {
	t.Helper()
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
	client, err := storage.New(storage.Config{BaseURL: "https://storage.example", Bucket: "private", ServiceAccountJSON: string(account), Now: h.clock.Now})
	if err != nil {
		t.Fatalf("storage.New: %v", err)
	}
	return client
}

func (h *harness) selfie(t *testing.T, driver uuid.UUID, key, status, scan string, purged bool) {
	t.Helper()
	application := uuid.New()
	h.exec(t, `INSERT INTO verification_applications (id, driver_id, status, created_at, updated_at) VALUES ($1, $2, 'approved', now(), now())`, application, driver)
	h.exec(t, `INSERT INTO verification_documents (id, application_id, driver_id, document_type, version, status,
		storage_key, content_type, size_bytes, scan_status, purged_at, created_at, updated_at)
		VALUES (gen_random_uuid(), $1, $2, 'driver_selfie_liveness', 1, $3, $4, 'image/jpeg', 1, $5, CASE WHEN $6::boolean THEN now() END, now(), now())`,
		application, driver, status, key, scan, purged)
}

func TestDriverPhotoIsTheirApprovedSelfie(t *testing.T) {
	tests := []struct {
		name    string
		consent bool
		status  string
		scan    string
		purged  bool
		want    bool
	}{
		{name: "approved selfie with consent", consent: true, status: "validated", scan: "clean", want: true},
		{name: "no consent", status: "validated", scan: "clean"},
		{name: "not reviewed yet", consent: true, status: "pending_review", scan: "clean"},
		{name: "turned down", consent: true, status: "rejected", scan: "clean"},
		{name: "not scanned", consent: true, status: "validated", scan: "pending"},
		{name: "file removed", consent: true, status: "validated", scan: "clean", purged: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			ride, rider, driver := h.acceptedRide(t)
			h.selfie(t, driver, "selfies/asha.jpg", tt.status, tt.scan, tt.purged)
			if tt.consent {
				h.exec(t, `UPDATE drivers SET photo_consent_at = now() WHERE user_id = $1`, driver)
			}
			svc := rides.NewService(rides.Config{Pool: h.pool, Routes: maps.NewClient("https://routes.example", "key"), Storage: signingClient(t, h), Now: h.clock.Now})
			seen, err := svc.Get(t.Context(), ride.ID, rider)
			if err != nil {
				t.Fatalf("Get: %v", err)
			}
			if got := seen.Driver.PhotoURL != nil; got != tt.want {
				t.Fatalf("has photo = %v, want %v", got, tt.want)
			}
			if !tt.want {
				return
			}
			link, err := url.Parse(*seen.Driver.PhotoURL)
			if err != nil {
				t.Fatalf("parse photo link: %v", err)
			}
			if !strings.HasSuffix(link.Path, "selfies/asha.jpg") || link.Query().Get("X-Goog-Expires") != "300" {
				t.Errorf("photo link = %s, want a five-minute link to the selfie", link.Redacted())
			}
		})
	}
}

func TestCancelledRideStopsSharingTheDriversPhoto(t *testing.T) {
	h := newHarness(t)
	ride, rider, driver := h.acceptedRide(t)
	h.selfie(t, driver, "selfies/asha.jpg", "validated", "clean", false)
	h.exec(t, `UPDATE drivers SET photo_consent_at = now() WHERE user_id = $1`, driver)
	svc := rides.NewService(rides.Config{Pool: h.pool, Routes: maps.NewClient("https://routes.example", "key"), Storage: signingClient(t, h), Now: h.clock.Now})
	if _, err := h.rides.Cancel(t.Context(), ride.ID, rider, "rider_changed_mind"); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	seen, err := svc.Get(t.Context(), ride.ID, rider)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if seen.Driver != nil {
		t.Errorf("driver card outlived the trip: %+v", seen.Driver)
	}
}
