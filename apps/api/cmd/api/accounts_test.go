package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type accountWorld struct {
	base string
	stub *smsStub
	pool *pgxpool.Pool
	next int
}

func startAccountWorld(t *testing.T) *accountWorld {
	t.Helper()
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	t.Cleanup(provider.Close)
	base, _ := startServer(t, databaseURL, provider.URL)
	pool, err := pgxpool.New(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return &accountWorld{base: base, stub: stub, pool: pool}
}

func (w *accountWorld) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := w.pool.Exec(t.Context(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

// account signs a new person in and returns their token, id and phone.
func (w *accountWorld) account(t *testing.T, role string) (string, uuid.UUID, string) {
	t.Helper()
	w.next++
	phone := fmt.Sprintf("07120000%02d", w.next)
	access, _ := signIn(t, w.base, w.stub, phone, role)["access_token"].(string)
	var id uuid.UUID
	if err := w.pool.QueryRow(t.Context(), `SELECT id FROM users WHERE phone = $1`, "254"+phone[1:]).Scan(&id); err != nil {
		t.Fatalf("find user: %v", err)
	}
	return access, id, phone
}

// driverRow makes the driver profile that signing in alone does not create.
func (w *accountWorld) driverRow(t *testing.T, id uuid.UUID, verification string) {
	t.Helper()
	w.exec(t, `INSERT INTO drivers (user_id, vehicle_category_id, verification_status)
		VALUES ($1, (SELECT min(id) FROM vehicle_categories), $2)
		ON CONFLICT (user_id) DO UPDATE SET verification_status = EXCLUDED.verification_status`, id, verification)
}

func TestNameRulesEndToEnd(t *testing.T) {
	w := startAccountWorld(t)
	access, _, _ := w.account(t, "rider")
	tests := []struct {
		name   string
		input  string
		status int
		want   string
	}{
		{name: "spaces are tidied", input: "  Wanjiru   Kamau ", status: http.StatusOK, want: "Wanjiru Kamau"},
		{name: "apostrophes and hyphens are names", input: "Ng'ang'a Wa-Kamau", status: http.StatusOK, want: "Ng'ang'a Wa-Kamau"},
		{name: "a phone number is not a name", input: "0712345678", status: http.StatusUnprocessableEntity},
		{name: "one letter is too short", input: "A", status: http.StatusUnprocessableEntity},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := send(t, http.MethodPatch, w.base+"/v1/me", access, map[string]string{"display_name": tt.input})
			if got.status != tt.status {
				t.Fatalf("PATCH /v1/me = %d %v, want %d", got.status, got.body, tt.status)
			}
			if tt.want == "" {
				return
			}
			if me := send(t, http.MethodGet, w.base+"/v1/me", access, nil); me.body["display_name"] != tt.want {
				t.Errorf("display_name = %v, want %q", me.body["display_name"], tt.want)
			}
		})
	}
}

func TestVerifiedDriverCannotRenameThemselves(t *testing.T) {
	w := startAccountWorld(t)
	access, id, _ := w.account(t, "driver")
	w.driverRow(t, id, "approved")
	got := send(t, http.MethodPatch, w.base+"/v1/me", access, map[string]string{"display_name": "Someone Else"})
	if got.status != http.StatusConflict || got.body["code"] != "NAME_LOCKED" {
		t.Fatalf("PATCH /v1/me = %d %v", got.status, got.body)
	}
}

func TestAccountDeletionIsRefused(t *testing.T) {
	w := startAccountWorld(t)
	seed := &testdb.Seeder{Pool: w.pool}
	tests := []struct {
		name   string
		setup  func(t *testing.T, id uuid.UUID)
		status int
		code   string
	}{
		{name: "sign-in is too old", status: http.StatusForbidden, code: "FRESH_SIGN_IN_REQUIRED", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			w.exec(t, `UPDATE auth_sessions SET created_at = now() - interval '16 minutes' WHERE user_id = $1`, id)
		}},
		{name: "account is suspended", status: http.StatusForbidden, code: "ACCOUNT_SUSPENDED", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			w.exec(t, `UPDATE users SET account_status = 'suspended' WHERE id = $1`, id)
		}},
		{name: "account is restricted", status: http.StatusConflict, code: "ACCOUNT_HAS_PENALTY", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			w.exec(t, `UPDATE users SET account_status = 'restricted' WHERE id = $1`, id)
		}},
		{name: "bookings are paused", status: http.StatusConflict, code: "ACCOUNT_HAS_PENALTY", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			w.exec(t, `UPDATE users SET booking_restricted_until = now() + interval '1 hour' WHERE id = $1`, id)
		}},
		{name: "trip in progress", status: http.StatusConflict, code: "TRIP_IN_PROGRESS", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			seed.Ride(t, testdb.Ride{Rider: id, Status: "searching", FareKES: 200, Ended: time.Now().Add(time.Hour)})
		}},
		{name: "staff are closed by an administrator", status: http.StatusForbidden, code: "STAFF_ACCOUNT", setup: func(t *testing.T, id uuid.UUID) {
			t.Helper()
			w.exec(t, `INSERT INTO user_roles (user_id, role) VALUES ($1, 'ops')`, id)
		}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			access, id, _ := w.account(t, "rider")
			tt.setup(t, id)
			got := send(t, http.MethodDelete, w.base+"/v1/me", access, nil)
			if got.status != tt.status || got.body["code"] != tt.code {
				t.Fatalf("DELETE /v1/me = %d %v, want %d %s", got.status, got.body, tt.status, tt.code)
			}
			var phone *string
			if err := w.pool.QueryRow(t.Context(), `SELECT phone FROM users WHERE id = $1`, id).Scan(&phone); err != nil || phone == nil {
				t.Errorf("phone after refusal = %v, %v", phone, err)
			}
		})
	}
}

func TestDeletedAccountLosesItsDetailsButKeepsRecords(t *testing.T) {
	w := startAccountWorld(t)
	access, id, phone := w.account(t, "driver")
	seed := &testdb.Seeder{Pool: w.pool}
	other := seed.User(t, "driver")
	ride := seed.Ride(t, testdb.Ride{Rider: id, Driver: &other, Status: "completed", FareKES: 300, Ended: time.Now().Add(-time.Hour)})
	w.exec(t, `UPDATE users SET display_name = 'Asha Njeri', email = 'asha@example.com' WHERE id = $1`, id)
	w.driverRow(t, id, "pending")
	w.exec(t, `UPDATE drivers SET plate_number = 'KMFB123A', is_online = true, photo_consent_at = now() WHERE user_id = $1`, id)
	w.exec(t, `INSERT INTO driver_locations (driver_id, lat, lng, captured_at) VALUES ($1, -1.29, 36.82, now())`, id)
	w.exec(t, `INSERT INTO notifications (user_id, event_type) VALUES ($1, 'ride.status')`, id)
	w.exec(t, `INSERT INTO auth_identities (provider, subject, user_id, created_at, last_used_at) VALUES ('google', 'sub-1', $1, now(), now())`, id)

	if got := send(t, http.MethodDelete, w.base+"/v1/me", access, nil); got.status != http.StatusNoContent {
		t.Fatalf("DELETE /v1/me = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodGet, w.base+"/v1/me", access, nil); got.status != http.StatusUnauthorized {
		t.Errorf("old token = %d, want 401", got.status)
	}

	var left, rides int
	err := w.pool.QueryRow(t.Context(), `SELECT
		(SELECT count(*) FROM users WHERE id = $1 AND (phone IS NOT NULL OR email IS NOT NULL OR display_name IS NOT NULL OR deleted_at IS NULL OR account_status <> 'deactivated'))
		+ (SELECT count(*) FROM drivers WHERE user_id = $1 AND (is_online OR plate_number IS NOT NULL OR photo_consent_at IS NOT NULL))
		+ (SELECT count(*) FROM driver_locations WHERE driver_id = $1)
		+ (SELECT count(*) FROM notifications WHERE user_id = $1)
		+ (SELECT count(*) FROM auth_identities WHERE user_id = $1)
		+ (SELECT count(*) FROM auth_sessions WHERE user_id = $1 AND revoked_at IS NULL),
		(SELECT count(*) FROM rides WHERE id = $2 AND rider_id = $1)`, id, ride).Scan(&left, &rides)
	if err != nil {
		t.Fatalf("inspect account: %v", err)
	}
	if left != 0 || rides != 1 {
		t.Errorf("personal rows left = %d, ride records = %d; want 0 and 1", left, rides)
	}

	// The number is free again, for a new and separate account. Moving the last
	// code back an hour clears the per-phone cooldown.
	w.exec(t, `UPDATE auth_challenges SET created_at = created_at - interval '1 hour'`)
	again, _ := signIn(t, w.base, w.stub, phone, "rider")["access_token"].(string)
	me := send(t, http.MethodGet, w.base+"/v1/me", again, nil)
	if me.status != http.StatusOK || me.body["id"] == id.String() || me.body["display_name"] != nil {
		t.Errorf("new account = %d %v", me.status, me.body)
	}
}
