package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

// TestStaffRoutesAreGatedAndBansTakeEffect drives the moderation surface
// through the real server: who can reach it, and what a ban actually does.
func TestStaffRoutesAreGatedAndBansTakeEffect(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	base, _ := startServer(t, databaseURL, provider.URL)
	grantStaff(t, databaseURL, "0700000001", "ops")

	rider, _ := signIn(t, base, stub, "0711111111", "rider")["access_token"].(string)
	session := signIn(t, base, stub, "0722222222", "driver")
	driver, _ := session["access_token"].(string)
	driverID, _ := session["user_id"].(string)
	staff, secret := enrolStaff(t, base, stub, "0700000001")

	queue := base + "/v1/ops/moderation/reports?status=submitted"
	for name, token := range map[string]string{"rider": rider, "driver": driver} {
		if got := send(t, http.MethodGet, queue, token, nil); got.status != http.StatusForbidden {
			t.Errorf("%s reading reports = %d", name, got.status)
		}
	}
	if got := send(t, http.MethodGet, queue, "", nil); got.status != http.StatusUnauthorized {
		t.Errorf("anonymous reading reports = %d", got.status)
	}
	if got := send(t, http.MethodGet, queue, staff, nil); got.status != http.StatusOK {
		t.Errorf("staff reading reports = %d %v", got.status, got.body)
	}

	penalty := base + "/v1/ops/moderation/enforcements"
	body := map[string]any{"user_id": driverID, "action": "permanent_ban", "reason_code": "test"}
	if got := send(t, http.MethodPost, penalty, staff, body); got.status != http.StatusForbidden || got.body["code"] != "STEP_UP_REQUIRED" {
		t.Errorf("ban without step-up = %d %v", got.status, got.body)
	}
	grant := stepUp(t, base, staff, secret, 30*time.Second)
	if got := sendWithHeader(t, http.MethodPost, penalty, staff, headerStepUp, grant, body); got.status != http.StatusCreated {
		t.Fatalf("ban = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodGet, base+"/v1/me", driver, nil); got.status != http.StatusForbidden || got.body["code"] != "ACCOUNT_BANNED" {
		t.Errorf("banned driver = %d %v", got.status, got.body)
	}
}

func TestCompletingARideOpensRatings(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	google := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, `{"routes":[{"distanceMeters":5000,"duration":"900s","polyline":{"encodedPolyline":"x"}}]}`)
	}))
	defer google.Close()
	base, _ := startServerWithRoutes(t, databaseURL, provider.URL, google.URL)

	rider, _ := signIn(t, base, stub, "0711111111", "rider")["access_token"].(string)
	driver, _ := signIn(t, base, stub, "0722222222", "driver")["access_token"].(string)
	if got := send(t, http.MethodPut, base+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
		t.Fatalf("set category = %d", got.status)
	}
	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(context.WithoutCancel(t.Context())) }() // Only test setup used it.
	if _, err := db.Exec(t.Context(), `UPDATE drivers SET verification_status = 'approved', subscription_status = 'active'`); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if got := send(t, http.MethodPost, base+"/v1/drivers/me/online", driver, nil); got.status != http.StatusNoContent {
		t.Fatalf("online = %d", got.status)
	}
	pickup := map[string]float64{"lat": -1.2921, "lng": 36.8219}
	dropoff := map[string]float64{"lat": -1.30, "lng": 36.80}
	move := func(point map[string]float64) {
		t.Helper()
		if _, err := db.Exec(t.Context(), `UPDATE driver_locations SET captured_at = now() - interval '1 minute'`); err != nil {
			t.Fatalf("age location: %v", err)
		}
		if got := send(t, http.MethodPost, base+"/v1/drivers/me/location", driver, point); got.status != http.StatusNoContent {
			t.Fatalf("location = %d %v", got.status, got.body)
		}
	}
	move(pickup)
	quote := send(t, http.MethodPost, base+"/v1/rides/quotes", rider, map[string]any{"vehicle_category": "motorbike", "pickup": pickup, "dropoff": dropoff})
	ride := send(t, http.MethodPost, base+"/v1/rides", rider, map[string]any{"quote_id": quote.body["id"]})
	offer := waitForOffer(t, base, driver)
	if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/offers/%s/accept", base, offer["id"]), driver, nil); got.status != http.StatusOK {
		t.Fatalf("accept = %d %v", got.status, got.body)
	}
	id := ride.body["id"]
	for _, step := range []struct {
		path string
		body any
	}{{"arrived", nil}, {"start", nil}} {
		if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/rides/%s/%s", base, id, step.path), driver, step.body); got.status != http.StatusOK {
			t.Fatalf("%s = %d %v", step.path, got.status, got.body)
		}
	}
	move(dropoff)
	if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/rides/%s/complete", base, id), driver, map[string]string{"payment_mode": "cash_direct"}); got.status != http.StatusOK {
		t.Fatalf("complete = %d %v", got.status, got.body)
	}

	pending := send(t, http.MethodGet, base+"/v1/ratings/pending", rider, nil)
	if list, _ := pending.body["data"].([]any); len(list) != 1 {
		t.Fatalf("pending = %v", pending.body)
	}
	if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/rides/%s/rate", base, id), rider, map[string]any{"score": 5}); got.status != http.StatusNoContent {
		t.Errorf("rate = %d %v", got.status, got.body)
	}
	dispute := send(t, http.MethodPost, base+"/v1/disputes", rider, map[string]any{"ride_id": id, "dispute_type": "fare_dispute", "description": "charged twice"})
	if dispute.status != http.StatusCreated {
		t.Errorf("dispute = %d %v", dispute.status, dispute.body)
	}
}
