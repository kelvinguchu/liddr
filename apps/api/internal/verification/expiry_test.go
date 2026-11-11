package verification

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type world struct {
	pool    *pgxpool.Pool
	service *Service
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	w.service = NewService(Config{Pool: w.pool, Now: func() time.Time { return w.now }})
	return w
}

func (w *world) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := w.pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("exec %s: %v", sql, err)
	}
}

// approvedDriver creates a driver and an application for them.
func (w *world) approvedDriver(t *testing.T, phone string) (driverID, applicationID uuid.UUID) {
	t.Helper()
	driverID, applicationID = uuid.New(), uuid.New()
	w.exec(t, `INSERT INTO users (id, phone) VALUES ($1, $2)`, driverID, phone)
	w.exec(t, `INSERT INTO drivers (user_id, vehicle_category_id, verification_status, is_online)
		VALUES ($1, (SELECT min(id) FROM vehicle_categories), 'approved', true)`, driverID)
	w.exec(t, `INSERT INTO verification_applications (id, driver_id, status, created_at, updated_at)
		VALUES ($1, $2, 'approved', now(), now())`, applicationID, driverID)
	return driverID, applicationID
}

func (w *world) document(t *testing.T, driverID, applicationID uuid.UUID, version int, status string, expires time.Time) {
	t.Helper()
	w.exec(t, `INSERT INTO verification_documents (id, application_id, driver_id, document_type, version, status,
		storage_key, content_type, size_bytes, expires_on, scan_status, created_at, updated_at)
		VALUES (gen_random_uuid(), $1, $2, 'drivers_licence', $3, $4, gen_random_uuid()::text, 'image/jpeg', 1, $5, 'clean', now(), now())`,
		applicationID, driverID, version, status, expires)
}

func (w *world) driverState(t *testing.T, id uuid.UUID) (string, bool) {
	t.Helper()
	var status string
	var online bool
	if err := w.pool.QueryRow(t.Context(), `SELECT verification_status, is_online FROM drivers WHERE user_id = $1`, id).Scan(&status, &online); err != nil {
		t.Fatalf("read driver: %v", err)
	}
	return status, online
}

func TestExpiry(t *testing.T) {
	cases := []struct {
		name       string
		status     string
		expires    time.Time
		wantDriver string
		wantOnline bool
	}{
		{"lapsed yesterday suspends", "validated", time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC), "suspended", false},
		{"valid through today stays", "validated", time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC), "approved", true},
		{"superseded copy never counts", "superseded", time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC), "approved", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			driver, application := w.approvedDriver(t, "254711111111")
			w.document(t, driver, application, 1, tc.status, tc.expires)
			for range 2 {
				if err := w.service.ExpireDocuments(t.Context()); err != nil {
					t.Fatalf("ExpireDocuments: %v", err)
				}
			}
			status, online := w.driverState(t, driver)
			if status != tc.wantDriver || online != tc.wantOnline {
				t.Errorf("driver = %s online=%v, want %s online=%v", status, online, tc.wantDriver, tc.wantOnline)
			}
		})
	}
}

func TestExpiryUsesNairobiDate(t *testing.T) {
	w := newWorld(t)
	// 21:30 UTC on 31 May is already 1 June in Nairobi.
	w.now = time.Date(2026, 5, 31, 21, 30, 0, 0, time.UTC)
	driver, application := w.approvedDriver(t, "254711111111")
	w.document(t, driver, application, 1, "validated", time.Date(2026, 5, 31, 0, 0, 0, 0, time.UTC))
	if err := w.service.ExpireDocuments(context.WithoutCancel(t.Context())); err != nil {
		t.Fatalf("ExpireDocuments: %v", err)
	}
	if status, _ := w.driverState(t, driver); status != "suspended" {
		t.Errorf("driver = %s, want suspended", status)
	}
}

func TestStaffCannotReviewThemselves(t *testing.T) {
	w := newWorld(t)
	driver, application := w.approvedDriver(t, "254711111111")
	w.exec(t, `UPDATE verification_applications SET status = 'under_review' WHERE id = $1`, application)
	err := w.service.ReviewApplication(t.Context(), application, decisionReject, new("no"), Actor{UserID: driver})
	if err != ErrSelfReview { //nolint:errorlint // The sentinel is returned unwrapped.
		t.Errorf("ReviewApplication = %v, want ErrSelfReview", err)
	}
}
