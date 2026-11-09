package main

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

var (
	goodFile = append([]byte("\xff\xd8\xff"), []byte("a photo of a document")...)
	expiring = map[string]bool{"drivers_licence": true, "psv_badge": true, "good_conduct_certificate": true, "commercial_insurance": true}
	required = []string{
		"national_id_front", "national_id_back", "drivers_licence", "psv_badge", "good_conduct_certificate",
		"vehicle_logbook", "commercial_insurance", "vehicle_photo_front", "vehicle_photo_back",
		"vehicle_photo_side", "driver_selfie_liveness",
	}
)

func (w verificationWorld) submit(t *testing.T, token, documentType, upload string) response {
	t.Helper()
	body := map[string]any{"upload_id": upload}
	if expiring[documentType] {
		body["expires_on"] = time.Now().AddDate(1, 0, 0).Format(time.DateOnly)
	}
	return send(t, http.MethodPost, w.baseURL+"/v1/verification/documents", token, body)
}

// waitFor polls a driver's status, with one deadline, until check accepts it.
func (w verificationWorld) waitFor(t *testing.T, token string, check func(response) bool) response {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		status := send(t, http.MethodGet, w.baseURL+"/v1/verification/status", token, nil)
		if status.status == http.StatusOK && check(status) {
			return status
		}
		if time.Now().After(deadline) {
			t.Fatalf("status never reached the expected state: %v", status.body)
		}
		<-ticker.C
	}
}

func requirementStatus(status response, documentType string) string {
	list, _ := status.body["requirements"].([]any)
	for _, item := range list {
		entry, _ := item.(map[string]any)
		if entry["document_type"] == documentType {
			doc, _ := entry["document"].(map[string]any)
			value, _ := doc["status"].(string)
			return value
		}
	}
	return ""
}

func documentID(status response, documentType string) string {
	list, _ := status.body["requirements"].([]any)
	for _, item := range list {
		entry, _ := item.(map[string]any)
		if entry["document_type"] == documentType {
			doc, _ := entry["document"].(map[string]any)
			value, _ := doc["id"].(string)
			return value
		}
	}
	return ""
}

func TestDriverVerificationEndToEnd(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	world := startVerificationWorld(t, databaseURL, stub)
	base := world.baseURL
	grantStaff(t, databaseURL, "0700000001", "ops")

	token := func(phone, role string) string {
		value, _ := signIn(t, base, stub, phone, role)["access_token"].(string)
		return value
	}
	driver := token("0711111111", "driver")
	other := token("0722222222", "driver")
	for _, account := range []string{driver, other} {
		if got := send(t, http.MethodPut, base+"/v1/drivers/me", account, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
			t.Fatalf("set category = %d %v", got.status, got.body)
		}
	}

	if got := send(t, http.MethodPost, base+"/v1/verification/applications", driver, map[string]string{"plate_number": "nonsense"}); got.status != http.StatusBadRequest {
		t.Errorf("bad plate = %d %v", got.status, got.body)
	}
	application := send(t, http.MethodPost, base+"/v1/verification/applications", driver, map[string]string{"plate_number": "kmfb 123a"})
	if application.status != http.StatusCreated {
		t.Fatalf("start = %d %v", application.status, application.body)
	}

	// A file promised but never sent, and another driver's upload, are refused.
	notSent := send(t, http.MethodPost, base+"/v1/verification/uploads", driver, map[string]any{"document_type": "psv_badge", "content_type": "image/jpeg", "size_bytes": 10})
	if got := send(t, http.MethodPost, base+"/v1/verification/documents", driver, map[string]any{"upload_id": notSent.body["upload_id"], "expires_on": "2099-01-01"}); got.status != http.StatusConflict {
		t.Errorf("file never sent = %d %v", got.status, got.body)
	}
	short := world.uploadFile(t, driver, "psv_badge", goodFile)
	world.overwrite(t, short, goodFile[:4])
	if got := world.submit(t, driver, "psv_badge", short); got.status != http.StatusConflict || got.body["code"] != "UPLOAD_NOT_FOUND" {
		t.Errorf("file shorter than promised = %d %v", got.status, got.body)
	}
	stolen := world.uploadFile(t, driver, "national_id_front", goodFile)
	if got := world.submit(t, other, "national_id_front", stolen); got.status != http.StatusNotFound {
		t.Errorf("another driver's upload = %d %v", got.status, got.body)
	}

	for _, kind := range required {
		upload := world.uploadFile(t, driver, kind, goodFile)
		if got := world.submit(t, driver, kind, upload); got.status != http.StatusCreated {
			t.Fatalf("submit %s = %d %v", kind, got.status, got.body)
		}
		if kind == "national_id_front" {
			if got := world.submit(t, driver, kind, upload); got.status != http.StatusConflict {
				t.Errorf("reused upload = %d %v", got.status, got.body)
			}
		}
	}
	status := world.waitFor(t, driver, func(r response) bool { return r.body["driver_status"] == "under_review" })
	for _, kind := range required {
		if got := requirementStatus(status, kind); got != "pending_review" {
			t.Errorf("%s = %q, want pending_review", kind, got)
		}
	}

	appID := application.body["id"]
	review := fmt.Sprintf("%s/v1/ops/verification/applications/%s/review", base, appID)
	queue := base + "/v1/ops/verification/applications?status=under_review"

	if got := send(t, http.MethodGet, queue, driver, nil); got.status != http.StatusForbidden {
		t.Errorf("driver reading the queue = %d", got.status)
	}
	unenrolled := token("0700000001", "staff")
	if got := send(t, http.MethodGet, queue, unenrolled, nil); got.status != http.StatusForbidden || got.body["code"] != "MFA_ENROLMENT_REQUIRED" {
		t.Errorf("staff without authenticator = %d %v", got.status, got.body)
	}
	staff, secret := unenrolled, enrol(t, base, unenrolled)
	if got := send(t, http.MethodGet, queue, staff, nil); got.status != http.StatusOK || len(got.body["data"].([]any)) != 1 {
		t.Errorf("queue = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodPost, review, staff, map[string]string{"decision": "approve"}); got.status != http.StatusForbidden || got.body["code"] != "STEP_UP_REQUIRED" {
		t.Errorf("approve without step-up = %d %v", got.status, got.body)
	}
	grant := stepUp(t, base, staff, secret, 30*time.Second)
	if got := sendWithHeader(t, http.MethodPost, review, staff, headerStepUp, grant, map[string]string{"decision": "approve"}); got.status != http.StatusConflict || got.body["code"] != "DOCUMENTS_INCOMPLETE" {
		t.Errorf("approve with unreviewed documents = %d %v", got.status, got.body)
	}

	for _, kind := range required {
		target := fmt.Sprintf("%s/v1/ops/verification/documents/%s/review", base, documentID(status, kind))
		if got := sendWithHeader(t, http.MethodPost, target, staff, headerStepUp, grant, map[string]string{"decision": "approve"}); got.status != http.StatusNoContent {
			t.Fatalf("validate %s = %d %v", kind, got.status, got.body)
		}
	}
	link := send(t, http.MethodPost, fmt.Sprintf("%s/v1/ops/verification/documents/%s/download", base, documentID(status, "psv_badge")), staff, nil)
	if link.status != http.StatusOK || link.body["url"] == "" {
		t.Errorf("download = %d %v", link.status, link.body)
	}
	if got := sendWithHeader(t, http.MethodPost, review, staff, headerStepUp, grant, map[string]string{"decision": "approve"}); got.status != http.StatusNoContent {
		t.Fatalf("approve = %d %v", got.status, got.body)
	}
	if got := send(t, http.MethodGet, base+"/v1/verification/status", driver, nil); got.body["driver_status"] != "approved" {
		t.Errorf("driver after approval = %v", got.body)
	}
	if got := sendWithHeader(t, http.MethodPost, review, staff, headerStepUp, grant, map[string]string{"decision": "reject", "reason": "changed my mind"}); got.status != http.StatusConflict {
		t.Errorf("deciding twice = %d %v", got.status, got.body)
	}

	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(context.WithoutCancel(t.Context())) }() // Only assertions used it.
	var views int
	if err := db.QueryRow(t.Context(), `SELECT count(*) FROM audit_events WHERE action = 'verification.document_viewed' AND target IS NOT NULL`).Scan(&views); err != nil || views != 1 {
		t.Errorf("audited document views = %d, %v", views, err)
	}
	var decisions int
	if err := db.QueryRow(t.Context(), `SELECT count(*) FROM verification_reviews WHERE reviewer_id IS NOT NULL`).Scan(&decisions); err != nil || decisions != len(required)+1 {
		t.Errorf("recorded decisions = %d, want %d, %v", decisions, len(required)+1, err)
	}
}

func TestUnsafeFilesNeverReachReview(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	world := startVerificationWorld(t, databaseURL, stub)
	base := world.baseURL
	grantStaff(t, databaseURL, "0700000001", "ops")
	driver, _ := signIn(t, base, stub, "0711111111", "driver")["access_token"].(string)
	if got := send(t, http.MethodPut, base+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
		t.Fatalf("set category = %d", got.status)
	}
	if got := send(t, http.MethodPost, base+"/v1/verification/applications", driver, map[string]string{"plate_number": "KMFB123A"}); got.status != http.StatusCreated {
		t.Fatalf("start = %d", got.status)
	}

	cases := []struct {
		name    string
		kind    string
		content []byte
	}{
		{"infected", "vehicle_logbook", append([]byte("\xff\xd8\xff"), []byte("EICAR")...)},
		{"not the declared type", "national_id_back", []byte("<script>not a jpeg</script>")},
	}
	staff, secret := enrolStaff(t, base, stub, "0700000001")
	grant := stepUp(t, base, staff, secret, 30*time.Second)
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := world.submit(t, driver, tc.kind, world.uploadFile(t, driver, tc.kind, tc.content)); got.status != http.StatusCreated {
				t.Fatalf("submit = %d %v", got.status, got.body)
			}
			status := world.waitFor(t, driver, func(r response) bool { return requirementStatus(r, tc.kind) == "rejected" })
			id := documentID(status, tc.kind)
			target := fmt.Sprintf("%s/v1/ops/verification/documents/%s/review", base, id)
			if got := sendWithHeader(t, http.MethodPost, target, staff, headerStepUp, grant, map[string]string{"decision": "approve"}); got.status != http.StatusConflict {
				t.Errorf("validate unsafe file = %d %v", got.status, got.body)
			}
			if got := send(t, http.MethodPost, fmt.Sprintf("%s/v1/ops/verification/documents/%s/download", base, id), staff, nil); got.status != http.StatusConflict {
				t.Errorf("download unsafe file = %d %v", got.status, got.body)
			}
		})
	}
}

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
