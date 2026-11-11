package sms

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"
)

const (
	testPhone   = "254712345678"
	testMessage = "Your code is 654321"
)

func testConfig(url string) Config {
	return Config{BaseURL: url, APIKey: "api-key", ClientID: "client-id", AccessKey: "access-key", SenderID: "LIDDR"}
}

func TestSendRequestShape(t *testing.T) {
	var got sendRequest
	var path, accessKey, contentType string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path, accessKey, contentType = r.URL.Path, r.Header.Get("AccessKey"), r.Header.Get("Content-Type")
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_, _ = w.Write([]byte(`{"ErrorCode":0,"ErrorDescription":"Success","Data":[{"MobileNumber":"254712345678","MessageId":"m-1"}]}`))
	}))
	defer server.Close()

	if err := NewClient(testConfig(server.URL+"/")).Send(t.Context(), testPhone, testMessage); err != nil {
		t.Fatalf("Send: %v", err)
	}
	want := sendRequest{
		APIKey: "api-key", ClientID: "client-id", SenderID: "LIDDR",
		MessageParameters: []messageParameter{{Number: testPhone, Text: testMessage}},
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("body mismatch (-got +want):\n%s", diff)
	}
	if path != "/v1/sms/SendBulkSMS" {
		t.Errorf("path = %q, want /v1/sms/SendBulkSMS", path)
	}
	if accessKey != "access-key" {
		t.Errorf("AccessKey = %q, want access-key", accessKey)
	}
	if contentType != "application/json" {
		t.Errorf("Content-Type = %q", contentType)
	}
}

func TestSendInterpretsResponses(t *testing.T) {
	tests := []struct {
		name   string
		status int
		body   string
		ok     bool
	}{
		{"numeric zero", 200, `{"ErrorCode":0,"ErrorDescription":"Success"}`, true},
		{"string triple zero", 200, `{"ErrorCode":"000","ErrorDescription":"Success"}`, true},
		{"lowercase key", 200, `{"errorCode":"0"}`, true},
		{"insufficient credit", 200, `{"ErrorCode":21,"ErrorDescription":"Insufficient wallet credits"}`, false},
		{"invalid sender as string", 200, `{"ErrorCode":"015"}`, false},
		{"no error code", 200, `{"ErrorDescription":"Success"}`, false},
		{"empty object", 200, `{}`, false},
		{"null code", 200, `{"ErrorCode":null}`, false},
		{"html body", 200, `<html>gateway</html>`, false},
		{"success code with server error", 500, `{"ErrorCode":0}`, false},
		{"unauthorized", 401, `{}`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()
			err := NewClient(testConfig(server.URL)).Send(t.Context(), testPhone, testMessage)
			if tt.ok && err != nil {
				t.Errorf("Send = %v, want nil", err)
			}
			if !tt.ok && !errors.Is(err, ErrRejected) {
				t.Errorf("Send = %v, want ErrRejected", err)
			}
		})
	}
}

func TestRejectionNamesTheProviderCode(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"ErrorCode":"021","ErrorDescription":"Insufficient wallet credits"}`))
	}))
	defer server.Close()
	err := NewClient(testConfig(server.URL)).Send(t.Context(), testPhone, testMessage)
	if err == nil || !strings.Contains(err.Error(), "021") {
		t.Errorf("Send = %v, want the provider code 021 for whoever reads the log", err)
	}
}

func TestSendErrorsNeverLeakRequestData(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"ErrorCode":13,"ErrorDescription":"Invalid mobile numbers ` + testPhone + ` ` + testMessage + `"}`))
	}))
	base := server.URL + "/?token=topsecret"
	err := NewClient(testConfig(base)).Send(t.Context(), testPhone, testMessage)
	server.Close()
	unreachable := NewClient(testConfig(base)).Send(t.Context(), testPhone, testMessage)

	for name, got := range map[string]error{"rejected": err, "unreachable": unreachable} {
		if got == nil {
			t.Fatalf("%s: Send returned nil", name)
		}
		for _, secret := range []string{testPhone, "654321", "topsecret", "access-key", "api-key"} {
			if strings.Contains(got.Error(), secret) {
				t.Errorf("%s: error %q leaked %q", name, got, secret)
			}
		}
	}
}
