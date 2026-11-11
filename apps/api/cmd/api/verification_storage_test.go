package main

import (
	"net/http"
	"testing"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestUploadsReportUnavailableWithoutStorage(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := newSMSServer(t, stub)
	baseURL, _ := startServer(t, databaseURL, provider)
	driver, _ := signIn(t, baseURL, stub, "0711111111", "driver")["access_token"].(string)
	got := send(t, http.MethodPost, baseURL+"/v1/verification/uploads", driver, map[string]any{"document_type": "psv_badge", "content_type": "image/jpeg", "size_bytes": 10})
	if got.status != http.StatusServiceUnavailable {
		t.Errorf("upload without storage = %d %v, want 503", got.status, got.body)
	}
}
