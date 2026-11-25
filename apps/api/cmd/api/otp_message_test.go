package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

const headerOTPAppHash = "X-Liddr-Otp-App-Hash"

// Android's SMS Retriever hands a message to the app only when it carries the
// app's 11-character hash and fits in 140 bytes. Browsers read the code from a
// last line of "@liddr.app #code" instead.
func TestSignInCodeMessage(t *testing.T) {
	databaseURL := testdb.URL(t)
	migrate(t, databaseURL)
	stub := &smsStub{}
	provider := httptest.NewServer(stub)
	defer provider.Close()
	baseURL, _ := startServer(t, databaseURL, provider.URL)

	cases := []struct {
		name, phone, hash string
		appLine           bool
	}{
		{name: "browser line without an app hash", phone: "0712 000 101"},
		{name: "app hash last for the Android app", phone: "0712 000 102", hash: "AB12cd3Ef+/", appLine: true},
		{name: "malformed app hash is ignored", phone: "0712 000 103", hash: "not a hash!"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			headerName := ""
			if tc.hash != "" {
				headerName = headerOTPAppHash
			}
			got := sendWithHeader(t, http.MethodPost, baseURL+"/v1/auth/otp/request", "", headerName, tc.hash, map[string]string{"phone": tc.phone, "role": "rider"})
			if got.status != http.StatusCreated {
				t.Fatalf("request code = %d %v", got.status, got.body)
			}
			text, code := stub.lastText(), stub.lastCode()
			if code == "" {
				t.Fatalf("no code found in %q", text)
			}
			want := "@liddr.app #" + code
			if tc.appLine {
				want = tc.hash
			}
			lines := strings.Split(text, "\n")
			if last := lines[len(lines)-1]; last != want {
				t.Errorf("last line = %q, want %q", last, want)
			}
			if len(text) > 140 {
				t.Errorf("message is %d bytes, want at most 140: %q", len(text), text)
			}
		})
	}
}
