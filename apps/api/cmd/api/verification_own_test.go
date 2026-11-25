package main

import (
	"fmt"
	"net/http"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

// A driver can see the files they sent, and nobody else's.
func TestDriverSeesOwnDocuments(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	world := startVerificationWorld(t, databaseURL, stub)
	base := world.baseURL
	token := func(phone, role string) string {
		value, _ := signIn(t, base, stub, phone, role)["access_token"].(string)
		return value
	}
	driver := token("0711111111", "driver")
	other := token("0722222222", "driver")
	rider := token("0733333333", "rider")
	for _, account := range []string{driver, other} {
		if got := send(t, http.MethodPut, base+"/v1/drivers/me", account, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
			t.Fatalf("set category = %d %v", got.status, got.body)
		}
		if got := send(t, http.MethodPost, base+"/v1/verification/applications", account, map[string]any{"plate_number": "KMFB123A", "full_name": "Asha Njeri", "photo_consent": true}); got.status != http.StatusCreated {
			t.Fatalf("start = %d %v", got.status, got.body)
		}
	}
	for kind, content := range map[string][]byte{"psv_badge": goodFile, "vehicle_logbook": append([]byte("\xff\xd8\xff"), []byte("EICAR")...)} {
		if got := world.submit(t, driver, kind, world.uploadFile(t, driver, kind, content)); got.status != http.StatusCreated {
			t.Fatalf("submit %s = %d %v", kind, got.status, got.body)
		}
	}
	status := world.waitFor(t, driver, func(r response) bool {
		return requirementStatus(r, "psv_badge") == "pending_review" && requirementStatus(r, "vehicle_logbook") == "rejected"
	})
	link := func(id string) string { return fmt.Sprintf("%s/v1/verification/documents/%s/download", base, id) }
	clean, infected := documentID(status, "psv_badge"), documentID(status, "vehicle_logbook")

	cases := []struct {
		name   string
		bearer string
		id     string
		want   int
	}{
		{"the driver who sent it", driver, clean, http.StatusOK},
		{"another driver", other, clean, http.StatusNotFound},
		{"a rider", rider, clean, http.StatusForbidden},
		{"signed out", "", clean, http.StatusUnauthorized},
		{"a file that failed its safety scan", driver, infected, http.StatusConflict},
		{"a document that does not exist", driver, "00000000-0000-4000-8000-000000000000", http.StatusNotFound},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := send(t, http.MethodPost, link(tc.id), tc.bearer, nil)
			if got.status != tc.want {
				t.Fatalf("status = %d %v, want %d", got.status, got.body, tc.want)
			}
			if tc.want == http.StatusOK && (got.body["url"] == "" || got.body["expires_at"] == nil) {
				t.Errorf("link = %v", got.body)
			}
		})
	}

	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(t.Context()) }() // Only assertions used it.
	var views int
	query := `SELECT count(*) FROM audit_events WHERE action = 'verification.own_document_viewed' AND target = $1`
	if err := db.QueryRow(t.Context(), query, "verification_document:"+clean).Scan(&views); err != nil || views != 1 {
		t.Errorf("audited views of the driver's own file = %d, %v", views, err)
	}
}

// A reviewer sees the applicant's full number on the application, so they can
// call or text them, and every look is audited. The queue stays masked.
func TestReviewerSeesApplicantPhone(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	world := startVerificationWorld(t, databaseURL, stub)
	base := world.baseURL
	grantStaff(t, databaseURL, "0700000001", "ops")
	driver, _ := signIn(t, base, stub, "0711111111", "driver")["access_token"].(string)
	if got := send(t, http.MethodPut, base+"/v1/drivers/me", driver, map[string]string{"vehicle_category": "motorbike"}); got.status != http.StatusOK {
		t.Fatalf("set category = %d %v", got.status, got.body)
	}
	application := send(t, http.MethodPost, base+"/v1/verification/applications", driver, map[string]any{"plate_number": "KMFB123A", "full_name": "Asha Njeri", "photo_consent": true})
	if application.status != http.StatusCreated {
		t.Fatalf("start = %d %v", application.status, application.body)
	}
	staff, _ := enrolStaff(t, base, stub, "0700000001")

	detail := send(t, http.MethodGet, fmt.Sprintf("%s/v1/ops/verification/applications/%s", base, application.body["id"]), staff, nil)
	if detail.status != http.StatusOK || detail.body["phone"] != "254711111111" {
		t.Fatalf("detail = %d, phone %v", detail.status, detail.body["phone"])
	}
	if summary, _ := detail.body["summary"].(map[string]any); summary["phone_masked"] != "****1111" {
		t.Errorf("summary phone = %v, want it masked", summary["phone_masked"])
	}
	if got := send(t, http.MethodGet, fmt.Sprintf("%s/v1/ops/verification/applications/%s", base, application.body["id"]), driver, nil); got.status != http.StatusForbidden {
		t.Errorf("driver reading an application = %d", got.status)
	}

	db, err := pgx.Connect(t.Context(), databaseURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer func() { _ = db.Close(t.Context()) }() // Only assertions used it.
	var views int
	query := `SELECT count(*) FROM audit_events WHERE action = 'verification.application_viewed' AND target = $1`
	if err := db.QueryRow(t.Context(), query, fmt.Sprintf("verification_application:%v", application.body["id"])).Scan(&views); err != nil || views != 1 {
		t.Errorf("audited application views = %d, %v", views, err)
	}
}
