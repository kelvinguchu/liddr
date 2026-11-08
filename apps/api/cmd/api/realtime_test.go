package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

// dialRealtime returns the connection, or the HTTP status of a refused upgrade.
func dialRealtime(t *testing.T, baseURL, token string) (*websocket.Conn, int, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), testTimeout)
	defer cancel()
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	conn, resp, err := websocket.Dial(ctx, strings.Replace(baseURL, "http://", "ws://", 1)+"/v1/realtime", &websocket.DialOptions{HTTPHeader: header})
	if resp == nil {
		return conn, 0, err
	}
	if resp.Body != nil {
		// The status is all that a refused upgrade tells us.
		_ = resp.Body.Close()
	}
	return conn, resp.StatusCode, err
}

// nextEvent reads frames until one has the wanted type.
func nextEvent(t *testing.T, conn *websocket.Conn, wantType string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), testTimeout)
	defer cancel()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %s: %v", wantType, err)
		}
		var event map[string]any
		if err := json.Unmarshal(data, &event); err != nil {
			t.Fatalf("decode %s: %v", data, err)
		}
		if event["type"] == wantType {
			return event
		}
	}
}

func TestLiveUpdatesReachTheRightPeople(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	google := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprint(w, `{"routes":[{"distanceMeters":5000,"duration":"900s","polyline":{"encodedPolyline":"x"}}]}`)
	}))
	defer google.Close()
	baseURL, _ := startServerWithRoutes(t, databaseURL, provider.URL, google.URL)

	if _, status, err := dialRealtime(t, baseURL, ""); err == nil || status != http.StatusUnauthorized {
		t.Errorf("unauthenticated dial = %d, %v", status, err)
	}

	token := func(phone, role string) string {
		value, _ := signIn(t, baseURL, stub, phone, role)["access_token"].(string)
		return value
	}
	rider, driver, stranger := token("0711111111", "rider"), token("0722222222", "driver"), token("0733333333", "rider")
	if got := send(t, http.MethodPut, baseURL+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
		t.Fatalf("set category = %d %v", got.status, got.body)
	}

	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(context.WithoutCancel(t.Context())) }() // Only test setup used it.
	if _, err := db.Exec(t.Context(), `UPDATE drivers SET verification_status = 'approved', subscription_status = 'active'`); err != nil {
		t.Fatalf("approve driver: %v", err)
	}
	if got := send(t, http.MethodPost, baseURL+"/v1/drivers/me/online", driver, nil); got.status != http.StatusNoContent {
		t.Fatalf("online = %d", got.status)
	}
	point := map[string]float64{"lat": -1.2921, "lng": 36.8219}
	if got := send(t, http.MethodPost, baseURL+"/v1/drivers/me/location", driver, point); got.status != http.StatusNoContent {
		t.Fatalf("location = %d", got.status)
	}

	sockets := map[string]*websocket.Conn{}
	for name, value := range map[string]string{"rider": rider, "driver": driver, "stranger": stranger} {
		conn, _, err := dialRealtime(t, baseURL, value)
		if err != nil {
			t.Fatalf("dial %s: %v", name, err)
		}
		defer func() { _ = conn.CloseNow() }() // The test is over; only cleanup remains.
		sockets[name] = conn
	}

	quote := send(t, http.MethodPost, baseURL+"/v1/rides/quotes", rider, map[string]any{
		"vehicle_category": "motorbike", "pickup": point, "dropoff": map[string]float64{"lat": -1.30, "lng": 36.80},
	})
	ride := send(t, http.MethodPost, baseURL+"/v1/rides", rider, map[string]any{"quote_id": quote.body["id"]})
	if ride.status != http.StatusCreated {
		t.Fatalf("book = %d %v", ride.status, ride.body)
	}

	offer := nextEvent(t, sockets["driver"], "offer.created")
	accepted := send(t, http.MethodPost, fmt.Sprintf("%s/v1/offers/%s/accept", baseURL, offer["offer_id"]), driver, nil)
	if accepted.status != http.StatusOK {
		t.Fatalf("accept = %d %v", accepted.status, accepted.body)
	}
	if got := nextEvent(t, sockets["rider"], "ride.status"); got["status"] != "accepted" || got["ride_id"] != ride.body["id"] {
		t.Errorf("rider got %v", got)
	}

	if _, err := db.Exec(t.Context(), `UPDATE driver_locations SET captured_at = now() - interval '1 minute'`); err != nil {
		t.Fatalf("age location: %v", err)
	}
	moved := map[string]float64{"lat": -1.2900, "lng": 36.8200}
	if got := send(t, http.MethodPost, baseURL+"/v1/drivers/me/location", driver, moved); got.status != http.StatusNoContent {
		t.Fatalf("location = %d %v", got.status, got.body)
	}
	if got := nextEvent(t, sockets["rider"], "driver.location"); got["lat"] != moved["lat"] {
		t.Errorf("location event = %v", got)
	}

	// Nothing above concerned this account, so its socket must have nothing to read.
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	if _, data, err := sockets["stranger"].Read(ctx); err == nil {
		t.Errorf("stranger received %s", data)
	}
}
