package sms

import (
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

func TestSendRequestShape(t *testing.T) {
	var form map[string]string
	var apiKey, contentType string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		apiKey, contentType = r.Header.Get("apikey"), r.Header.Get("Content-Type")
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		form = map[string]string{}
		for key := range r.PostForm {
			form[key] = r.PostForm.Get(key)
		}
		_, _ = w.Write([]byte(`{"status":"success"}`))
	}))
	defer server.Close()

	client := NewClient(Config{URL: server.URL, APIKey: "key", UserID: "user", Password: "pass", SenderID: "LIDDR"})
	if err := client.Send(t.Context(), testPhone, testMessage); err != nil {
		t.Fatalf("Send: %v", err)
	}

	want := map[string]string{
		"userid": "user", "password": "pass", "senderid": "LIDDR", "mobile": testPhone, "msg": testMessage,
		"msgType": "text", "duplicatecheck": "true", "output": "json", "sendMethod": "quick",
	}
	if diff := cmp.Diff(form, want); diff != "" {
		t.Errorf("form mismatch (-got +want):\n%s", diff)
	}
	if apiKey != "key" {
		t.Errorf("apikey = %q, want key", apiKey)
	}
	if contentType != "application/x-www-form-urlencoded" {
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
		{"status success", 200, `{"status":"success"}`, true},
		{"status mixed case", 200, `{"status":" SENT "}`, true},
		{"success flag", 200, `{"success":true}`, true},
		{"message id only", 200, `{"msgid":"abc"}`, true},
		{"numeric message id", 200, `{"messageId":12345}`, true},
		{"explicit failure beats message id", 200, `{"status":"error","msgid":"abc"}`, false},
		{"success false", 200, `{"success":false}`, false},
		{"empty object", 200, `{}`, false},
		{"null status", 200, `{"status":null}`, false},
		{"html body", 200, `<html>gateway</html>`, false},
		{"server error", 500, `{"status":"success"}`, false},
		{"unauthorized", 401, `{}`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()

			err := NewClient(Config{URL: server.URL}).Send(t.Context(), testPhone, testMessage)
			if tt.ok && err != nil {
				t.Errorf("Send = %v, want nil", err)
			}
			if !tt.ok && !errors.Is(err, ErrRejected) {
				t.Errorf("Send = %v, want ErrRejected", err)
			}
		})
	}
}

func TestSendErrorsNeverLeakRequestData(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"status":"error","message":"failed ` + testPhone + ` ` + testMessage + `"}`))
	}))
	url := server.URL + "/send?token=topsecret"
	err := NewClient(Config{URL: url}).Send(t.Context(), testPhone, testMessage)
	server.Close()
	unreachable := NewClient(Config{URL: url}).Send(t.Context(), testPhone, testMessage)

	for name, got := range map[string]error{"rejected": err, "unreachable": unreachable} {
		if got == nil {
			t.Fatalf("%s: Send returned nil", name)
		}
		for _, secret := range []string{testPhone, "654321", "topsecret"} {
			if strings.Contains(got.Error(), secret) {
				t.Errorf("%s: error %q leaked %q", name, got, secret)
			}
		}
	}
}
