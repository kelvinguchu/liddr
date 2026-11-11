package email

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSend(t *testing.T) {
	cases := []struct {
		name   string
		status int
		body   string
		want   error
	}{
		{"accepted", http.StatusOK, `{"id":"abc"}`, nil},
		{"refused", http.StatusUnprocessableEntity, `{"name":"validation_error"}`, ErrRejected},
		{"success with no id is not success", http.StatusOK, `{}`, ErrRejected},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got map[string]any
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_ = json.NewDecoder(r.Body).Decode(&got)
				if r.Header.Get("Authorization") != "Bearer key" {
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer server.Close()
			err := New(Config{URL: server.URL, APIKey: "key", From: "Liddr <a@b>"}).Send(t.Context(), "x@y.com", "subj", "secret 123456")
			if !errors.Is(err, tc.want) {
				t.Fatalf("Send = %v, want %v", err, tc.want)
			}
			if err != nil && (strings.Contains(err.Error(), "x@y.com") || strings.Contains(err.Error(), "123456")) {
				t.Errorf("error leaked its contents: %v", err)
			}
			if got["from"] != "Liddr <a@b>" {
				t.Errorf("request = %v", got)
			}
		})
	}
}
