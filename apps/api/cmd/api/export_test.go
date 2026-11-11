package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

// seedPrivateHistory gives two people a shared past, so an export can be
// checked for what must stay out of it as well as what must be in it.
func (w *accountWorld) seedPrivateHistory(t *testing.T, me, them uuid.UUID) {
	t.Helper()
	seed := &testdb.Seeder{Pool: w.pool}
	stranger := seed.User(t, "driver")
	ended := time.Now().Add(-time.Hour)
	w.driverRow(t, me, "approved")
	w.driverRow(t, them, "approved")
	w.exec(t, `UPDATE users SET display_name = 'Mine Myname', email = 'mine@example.com' WHERE id = $1`, me)
	w.exec(t, `UPDATE users SET display_name = 'Theirs Hername' WHERE id = $1`, them)
	asRider := seed.Ride(t, testdb.Ride{Rider: me, Driver: &them, Status: "completed", FareKES: 311, Ended: ended})
	seed.Ride(t, testdb.Ride{Rider: them, Driver: &me, Status: "completed", FareKES: 322, Ended: ended})
	seed.Ride(t, testdb.Ride{Rider: them, Driver: &stranger, Status: "completed", FareKES: 999, Ended: ended})
	joined := seed.Ride(t, testdb.Ride{Rider: them, Driver: &stranger, Status: "completed", FareKES: 888, Ended: ended})
	w.exec(t, `INSERT INTO shared_members (id, ride_id, rider_id, quote_id, status, fare_kes, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, requested_at)
		SELECT gen_random_uuid(), id, $2, quote_id, 'dropped_off', 144, -1.5, 36.5, -1.6, 36.6, now() FROM rides WHERE id = $1`, joined, me)

	rating := `INSERT INTO ride_ratings (id, ride_id, rated_by, rated_user, score, comment, include_in_score, submitted_at) VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, true, now())`
	w.exec(t, rating, asRider, me, them, 5, "my-own-comment")
	w.exec(t, rating, asRider, them, me, 1, "comment-about-me")
	report := `INSERT INTO reports (id, reporter_id, reported_id, category, status, severity, source, incident_type, ride_id, description, created_at, updated_at)
		SELECT gen_random_uuid(), $1, $2, min(slug), 'submitted', 2, 'in_app', 'conduct', $3::uuid, $4, now(), now() FROM report_categories`
	w.exec(t, report, me, them, asRider, "report-i-filed")
	w.exec(t, report, them, me, asRider, "accusation-against-me")
	message := `INSERT INTO ride_messages (id, ride_id, sender_id, recipient_id, sender_role, message_type, body, created_at) VALUES (gen_random_uuid(), $1, $2, $3, 'rider', 'text', $4, now())`
	w.exec(t, message, asRider, me, them, "message-i-sent")
	w.exec(t, message, asRider, them, me, "message-to-me")

	subscription := uuid.New()
	w.exec(t, `INSERT INTO subscriptions (id, driver_id, vehicle_category_id, week_start, week_end, amount_kes, status, reference, created_at)
		SELECT $1, user_id, vehicle_category_id, '2026-11-02', '2026-11-08', 1234, 'active', 'REF1', now() FROM drivers WHERE user_id = $2`, subscription, me)
	w.exec(t, `INSERT INTO subscription_payments (id, subscription_id, driver_id, channel, status, amount_kes, phone, checkout_request_id, receipt, requested_at)
		VALUES (gen_random_uuid(), $1, $2, 'stk', 'success', 1234, '254700000999', 'CHECKOUT-SECRET', 'RECEIPT-SECRET', now())`, subscription, me)
	application := uuid.New()
	w.exec(t, `INSERT INTO verification_applications (id, driver_id, status, created_at, updated_at) VALUES ($1, $2, 'approved', now(), now())`, application, me)
	w.exec(t, `INSERT INTO verification_documents (id, application_id, driver_id, document_type, version, status, storage_key, content_type, size_bytes, scan_status, created_at, updated_at)
		VALUES (gen_random_uuid(), $1, $2, 'drivers_licence', 1, 'validated', 'private/KEY-SECRET', 'image/jpeg', 1, 'clean', now(), now())`, application, me)
}

func TestExportHoldsOnlyWhatIsMine(t *testing.T) {
	w := startAccountWorld(t)
	access, me, _ := w.account(t, "rider")
	_, them, theirPhone := w.account(t, "rider")
	w.seedPrivateHistory(t, me, them)

	got := send(t, http.MethodGet, w.base+"/v1/me/export", access, nil)
	if got.status != http.StatusOK {
		t.Fatalf("GET /v1/me/export = %d %v", got.status, got.body)
	}
	raw, err := json.Marshal(got.body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	text := string(raw)
	for _, want := range []string{"Mine Myname", "mine@example.com", `"fare_kes":311`, `"fare_kes":322`, `"fare_kes":144`, `"lat":-1.5`, "my-own-comment", "report-i-filed", "message-i-sent", `"amount_kes":1234`, "drivers_licence"} {
		if !strings.Contains(text, want) {
			t.Errorf("export is missing %s", want)
		}
	}
	for _, leak := range []string{them.String(), "Theirs Hername", "254" + theirPhone[1:], `"fare_kes":999`, `"fare_kes":888`, "comment-about-me", "accusation-against-me", "message-to-me", "RECEIPT-SECRET", "CHECKOUT-SECRET", "254700000999", "KEY-SECRET"} {
		if strings.Contains(text, leak) {
			t.Errorf("export leaked %s", leak)
		}
	}
	rides, _ := got.body["rides"].([]any)
	roles := map[string]int{}
	for _, r := range rides {
		ride, _ := r.(map[string]any)
		role, _ := ride["role"].(string)
		roles[role]++
	}
	if len(rides) != 3 || roles["rider"] != 2 || roles["driver"] != 1 {
		t.Errorf("rides = %d, roles = %v; want two as rider and one as driver", len(rides), roles)
	}
}

func TestExportNeedsARecentSignIn(t *testing.T) {
	w := startAccountWorld(t)
	access, id, _ := w.account(t, "rider")
	w.exec(t, `UPDATE auth_sessions SET created_at = now() - interval '16 minutes' WHERE user_id = $1`, id)
	got := send(t, http.MethodGet, w.base+"/v1/me/export", access, nil)
	if got.status != http.StatusForbidden || got.body["code"] != "FRESH_SIGN_IN_REQUIRED" {
		t.Fatalf("GET /v1/me/export = %d %v", got.status, got.body)
	}
	w.assertExports(t, id, 0)
}

func TestExportIsLimitedAndAudited(t *testing.T) {
	w := startAccountWorld(t)
	access, id, _ := w.account(t, "rider")
	for i := range 3 {
		if got := send(t, http.MethodGet, w.base+"/v1/me/export", access, nil); got.status != http.StatusOK {
			t.Fatalf("export %d = %d %v", i+1, got.status, got.body)
		}
	}
	got := send(t, http.MethodGet, w.base+"/v1/me/export", access, nil)
	if got.status != http.StatusTooManyRequests || got.body["code"] != "EXPORT_LIMIT" {
		t.Fatalf("fourth export = %d %v", got.status, got.body)
	}
	w.assertExports(t, id, 3)
	// A day later the allowance is back.
	w.exec(t, `UPDATE audit_events SET created_at = created_at - interval '25 hours' WHERE user_id = $1 AND action = 'account.exported'`, id)
	if got := send(t, http.MethodGet, w.base+"/v1/me/export", access, nil); got.status != http.StatusOK {
		t.Errorf("export next day = %d %v", got.status, got.body)
	}
}

func (w *accountWorld) assertExports(t *testing.T, id uuid.UUID, want int) {
	t.Helper()
	var got int
	if err := w.pool.QueryRow(t.Context(), `SELECT count(*) FROM audit_events WHERE user_id = $1 AND action = 'account.exported'`, id).Scan(&got); err != nil {
		t.Fatalf("count audit: %v", err)
	}
	if got != want {
		t.Errorf("audited exports = %d, want %d", got, want)
	}
}
