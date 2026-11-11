package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestBookedRideReachesDriverEndToEnd(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	google := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, `{"routes":[{"distanceMeters":5000,"duration":"900s","polyline":{"encodedPolyline":"xyz"}}]}`)
	}))
	defer google.Close()
	baseURL, _ := startServerWithRoutes(t, databaseURL, provider.URL, google.URL)

	riderSession := signIn(t, baseURL, stub, "0711111111", "rider")
	rider, _ := riderSession["access_token"].(string)
	driverSession := signIn(t, baseURL, stub, "0722222222", "driver")
	driver, _ := driverSession["access_token"].(string)

	if got := send(t, http.MethodPost, baseURL+"/v1/drivers/me/online", rider, nil); got.status != http.StatusForbidden {
		t.Errorf("rider on a driver route = %d, want 403", got.status)
	}
	setup := send(t, http.MethodPut, baseURL+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "motorbike"})
	if setup.status != http.StatusOK {
		t.Fatalf("set category = %d %v", setup.status, setup.body)
	}
	blocked := send(t, http.MethodPost, baseURL+"/v1/drivers/me/online", driver, nil)
	if blocked.status != http.StatusForbidden || blocked.body["code"] != "DRIVER_NOT_VERIFIED" {
		t.Fatalf("unverified online = %d %v", blocked.status, blocked.body)
	}

	conn, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close(t.Context()) }() // Only test setup used it.
	if _, err := conn.Exec(t.Context(), `UPDATE drivers SET verification_status = 'approved', subscription_status = 'active'`); err != nil {
		t.Fatalf("approve driver: %v", err)
	}

	for path, want := range map[string]int{"/v1/drivers/me/online": http.StatusNoContent} {
		if got := send(t, http.MethodPost, baseURL+path, driver, nil); got.status != want {
			t.Fatalf("POST %s = %d %v", path, got.status, got.body)
		}
	}
	point := map[string]float64{"lat": -1.2921, "lng": 36.8219}
	if got := send(t, http.MethodPost, baseURL+"/v1/drivers/me/location", driver, point); got.status != http.StatusNoContent {
		t.Fatalf("location = %d %v", got.status, got.body)
	}

	quote := send(t, http.MethodPost, baseURL+"/v1/rides/quotes", rider, map[string]any{
		"vehicle_category": "motorbike",
		"pickup":           point,
		"dropoff":          map[string]float64{"lat": -1.30, "lng": 36.80},
	})
	if quote.status != http.StatusCreated {
		t.Fatalf("quote = %d %v", quote.status, quote.body)
	}
	ride := send(t, http.MethodPost, baseURL+"/v1/rides", rider, map[string]any{"quote_id": quote.body["id"]})
	if ride.status != http.StatusCreated || ride.body["status"] != "searching" {
		t.Fatalf("book = %d %v", ride.status, ride.body)
	}

	offer := waitForOffer(t, baseURL, driver)
	if _, leaked := offer["dropoff"]; leaked {
		t.Errorf("offer exposed the dropoff before acceptance: %v", offer)
	}
	accepted := send(t, http.MethodPost, fmt.Sprintf("%s/v1/offers/%s/accept", baseURL, offer["id"]), driver, nil)
	if accepted.status != http.StatusOK || accepted.body["status"] != "accepted" {
		t.Fatalf("accept = %d %v", accepted.status, accepted.body)
	}

	seen := send(t, http.MethodGet, fmt.Sprintf("%s/v1/rides/%s", baseURL, ride.body["id"]), rider, nil)
	if seen.status != http.StatusOK || seen.body["driver_location"] == nil {
		t.Errorf("rider view = %d %v", seen.status, seen.body)
	}
	missing := send(t, http.MethodPost, baseURL+"/v1/rides/not-a-uuid/cancel", rider, map[string]string{"reason": "emergency"})
	if missing.status != http.StatusBadRequest {
		t.Errorf("bad id = %d %v", missing.status, missing.body)
	}
}

// waitForOffer polls until the background dispatcher has offered the ride.
func waitForOffer(t *testing.T, baseURL, driver string) map[string]any {
	t.Helper()
	deadline := time.NewTimer(testTimeout)
	defer deadline.Stop()
	poll := time.NewTicker(50 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-deadline.C:
			t.Fatal("no offer arrived before the deadline")
		case <-poll.C:
			got := send(t, http.MethodGet, baseURL+"/v1/drivers/me/offers", driver, nil)
			if data, _ := got.body["data"].([]any); len(data) > 0 {
				offer, _ := data[0].(map[string]any)
				return offer
			}
		}
	}
}
