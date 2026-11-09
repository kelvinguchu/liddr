package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func (w verificationWorld) putProof(t *testing.T, driver, ride, kind string) string {
	t.Helper()
	prepared := send(t, http.MethodPost, fmt.Sprintf("%s/v1/send/rides/%s/proof-uploads", w.baseURL, ride), driver, map[string]any{
		"proof_kind": kind, "content_type": "image/jpeg", "size_bytes": len(goodFile),
	})
	if prepared.status != http.StatusCreated {
		t.Fatalf("prepare proof = %d %v", prepared.status, prepared.body)
	}
	target, _ := prepared.body["upload_url"].(string)
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPut, target, bytes.NewReader(goodFile))
	if err != nil {
		t.Fatalf("build put: %v", err)
	}
	headers, _ := prepared.body["headers"].(map[string]any)
	for name, value := range headers {
		text, _ := value.(string)
		req.Header.Set(name, text)
	}
	client := http.Client{Timeout: testTimeout, Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	_ = resp.Body.Close() // Only the status matters.
	id, _ := prepared.body["upload_id"].(string)
	return id
}

func TestSendDeliveryEndToEnd(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	world := startVerificationWorld(t, databaseURL, stub)
	base := world.baseURL

	token := func(phone, role string) string {
		value, _ := signIn(t, base, stub, phone, role)["access_token"].(string)
		return value
	}
	sender, driver, recipient, stranger := token("0711111111", "rider"), token("0722222222", "driver"), token("0733333333", "rider"), token("0744444444", "rider")
	if got := send(t, http.MethodPut, base+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "send"}); got.status != http.StatusOK {
		t.Fatalf("set category = %d %v", got.status, got.body)
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
	pickup, dropoff := map[string]float64{"lat": -1.2921, "lng": 36.8219}, map[string]float64{"lat": -1.30, "lng": 36.80}
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
	quote := send(t, http.MethodPost, base+"/v1/rides/quotes", sender, map[string]any{"vehicle_category": "send", "pickup": pickup, "dropoff": dropoff})
	if quote.status != http.StatusCreated {
		t.Fatalf("quote = %d %v", quote.status, quote.body)
	}
	if got := send(t, http.MethodPost, base+"/v1/rides", sender, map[string]any{"quote_id": quote.body["id"]}); got.status != http.StatusBadRequest || got.body["code"] != "WRONG_BOOKING_TYPE" {
		t.Errorf("booking a Send quote as a ride = %d %v", got.status, got.body)
	}

	request := func(item string, acknowledged bool) response {
		t.Helper()
		return send(t, http.MethodPost, base+"/v1/send/requests", sender, map[string]any{
			"quote_id": quote.body["id"], "sender_name": "Asha", "recipient_name": "Baraka", "recipient_phone": "0733333333",
			"item_description": item, "item_size": "small", "payer": "sender", "payment_timing": "after", "liability_acknowledged": acknowledged,
		})
	}
	if got := request("a bundle of cash", true); got.status != http.StatusUnprocessableEntity || got.body["code"] != "ITEM_PROHIBITED" {
		t.Errorf("prohibited item = %d %v", got.status, got.body)
	}
	if got := request("old electronics", false); got.status != http.StatusConflict || got.body["code"] != "LIABILITY_ACK_REQUIRED" {
		t.Errorf("warned item without acknowledgement = %d %v", got.status, got.body)
	}
	booked := request("bag of cashew nuts", false)
	if booked.status != http.StatusCreated {
		t.Fatalf("book = %d %v", booked.status, booked.body)
	}
	id, _ := booked.body["id"].(string)
	ridePath := fmt.Sprintf("%s/v1/rides/%s", base, id)
	sendPath := fmt.Sprintf("%s/v1/send/rides/%s", base, id)

	if got := send(t, http.MethodGet, sendPath, stranger, nil); got.status != http.StatusNotFound {
		t.Errorf("stranger reading a delivery = %d", got.status)
	}
	if got := send(t, http.MethodGet, sendPath, sender, nil); got.status != http.StatusOK || got.body["recipient_phone"] != nil {
		t.Errorf("sender view = %d %v", got.status, got.body)
	}

	offer := waitForOffer(t, base, driver)
	if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/offers/%s/accept", base, offer["id"]), driver, nil); got.status != http.StatusOK {
		t.Fatalf("accept = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, ridePath+"/arrived", driver, nil); got.status != http.StatusOK {
		t.Fatalf("arrived = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, ridePath+"/start", driver, nil); got.status != http.StatusConflict || got.body["code"] != "PICKUP_PROOF_REQUIRED" {
		t.Errorf("start without proof = %d %v", got.status, got.body)
	}

	wrongKind := world.putProof(t, driver, id, "dropoff")
	if got := send(t, http.MethodPost, sendPath+"/pickup-proof", driver, map[string]string{"upload_id": wrongKind}); got.status != http.StatusBadRequest {
		t.Errorf("dropoff upload used as pickup = %d %v", got.status, got.body)
	}
	proof := world.putProof(t, driver, id, "pickup")
	if got := send(t, http.MethodPost, sendPath+"/pickup-proof", driver, map[string]string{"upload_id": proof}); got.status != http.StatusNoContent {
		t.Fatalf("pickup proof = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, ridePath+"/cancel", sender, map[string]string{"reason": "rider_changed_mind"}); got.status != http.StatusConflict || got.body["code"] != "PACKAGE_COLLECTED" {
		t.Errorf("cancel after collection = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, ridePath+"/start", driver, nil); got.status != http.StatusOK {
		t.Fatalf("start = %d %v", got.status, got.body)
	}

	complete := func() response {
		t.Helper()
		return send(t, http.MethodPost, ridePath+"/complete", driver, map[string]string{"payment_mode": "cash_direct"})
	}
	move(dropoff)
	if got := complete(); got.status != http.StatusConflict || got.body["code"] != "DROPOFF_PROOF_REQUIRED" {
		t.Errorf("complete without proof = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, sendPath+"/recipient-confirm", recipient, nil); got.status != http.StatusConflict {
		t.Errorf("confirm before delivery = %d %v", got.status, got.body)
	}
	proof = world.putProof(t, driver, id, "dropoff")
	if got := send(t, http.MethodPost, sendPath+"/dropoff-proof", driver, map[string]string{"upload_id": proof}); got.status != http.StatusNoContent {
		t.Fatalf("dropoff proof = %d %v", got.status, got.body)
	}
	if got := complete(); got.status != http.StatusConflict || got.body["code"] != "RECIPIENT_PENDING" {
		t.Errorf("complete before confirmation = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, sendPath+"/recipient-confirm", stranger, nil); got.status != http.StatusNotFound {
		t.Errorf("stranger confirming = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, sendPath+"/recipient-confirm", recipient, nil); got.status != http.StatusNoContent {
		t.Fatalf("confirm = %d %v", got.status, got.body)
	}
	if got := complete(); got.status != http.StatusOK {
		t.Fatalf("complete = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodGet, sendPath, driver, nil); got.body["status"] != "completed" || got.body["recipient_phone"] != "254733333333" {
		t.Errorf("driver view = %v", got.body)
	}
}
