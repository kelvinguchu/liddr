package main

import (
	"net/http"
	"strings"
	"testing"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestMpesaWebhookRequiresTheToken(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	baseURL, output := startServer(t, databaseURL, "")
	callback := map[string]any{"Body": map[string]any{"stkCallback": map[string]any{
		"CheckoutRequestID": "ws_unknown", "ResultCode": 0, "ResultDesc": "ok",
	}}}

	refused := send(t, http.MethodPost, baseURL+"/v1/webhooks/mpesa/wrong-token/stk", "", callback)
	if refused.status != http.StatusUnauthorized {
		t.Errorf("wrong token = %d %v, want 401", refused.status, refused.body)
	}

	accepted := send(t, http.MethodPost, baseURL+"/v1/webhooks/mpesa/"+testCallbackToken+"/stk", "", callback)
	if accepted.status != http.StatusOK || accepted.body["ResultDesc"] != "Accepted" {
		t.Errorf("right token = %d %v", accepted.status, accepted.body)
	}
	if code, ok := accepted.body["ResultCode"].(float64); !ok || code != 0 {
		t.Errorf("ResultCode = %v, want the 0 Daraja expects", accepted.body["ResultCode"])
	}

	bad := send(t, http.MethodPost, baseURL+"/v1/webhooks/mpesa/"+testCallbackToken+"/stk", "", map[string]any{})
	if bad.status != http.StatusBadRequest {
		t.Errorf("unreadable callback = %d %v", bad.status, bad.body)
	}
	if strings.Contains(output.String(), testCallbackToken) {
		t.Error("logs leaked the callback token")
	}
}

func TestSubscriptionRoutesAreForDriversOnly(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	baseURL, _ := startServer(t, databaseURL, "")
	if got := send(t, http.MethodPost, baseURL+"/v1/subscriptions/pay", "", nil); got.status != http.StatusUnauthorized {
		t.Errorf("unauthenticated pay = %d, want 401", got.status)
	}
}
