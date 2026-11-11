package push

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func account(t *testing.T) string {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	out, err := json.Marshal(map[string]string{
		"client_email": "push@test.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	})
	if err != nil {
		t.Fatalf("marshal account: %v", err)
	}
	return string(out)
}

func TestSend(t *testing.T) {
	var tokenRequests atomic.Int32
	var lastBody atomic.Value
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/token" {
			tokenRequests.Add(1)
			_, _ = w.Write([]byte(`{"access_token":"access-1","expires_in":3600}`))
			return
		}
		if r.Header.Get("Authorization") != "Bearer access-1" || !strings.HasSuffix(r.URL.Path, "/v1/projects/liddr/messages:send") {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		var body struct {
			Message struct {
				Token string            `json:"token"`
				Data  map[string]string `json:"data"`
			} `json:"message"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		lastBody.Store(body.Message.Data["event_type"])
		switch body.Message.Token {
		case "gone":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
		case "throttled":
			w.WriteHeader(http.StatusTooManyRequests)
		case "plain-not-found":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"message":"UNREGISTERED appears only in prose"}}`))
		default:
			_, _ = w.Write([]byte(`{"name":"m"}`))
		}
	}))
	defer server.Close()
	now := time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)
	client, err := New(Config{BaseURL: server.URL, TokenURL: server.URL + "/token", ProjectID: "liddr", ServiceAccountJSON: account(t), Now: func() time.Time { return now }})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	cases := []struct {
		name  string
		token string
		want  error
	}{
		{"delivered", "good", nil},
		{"token gone", "gone", ErrUnregistered},
		{"throttled", "throttled", ErrUnavailable},
		{"prose is not a code", "plain-not-found", ErrUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := client.Send(t.Context(), Message{Token: tc.token, Data: map[string]string{"event_type": "ride.status"}, TTL: time.Minute})
			if !errors.Is(err, tc.want) {
				t.Errorf("Send = %v, want %v", err, tc.want)
			}
		})
	}
	if got := tokenRequests.Load(); got != 1 {
		t.Errorf("token requests = %d, want 1 (the token should be cached)", got)
	}
	if lastBody.Load() != "ride.status" {
		t.Errorf("data = %v", lastBody.Load())
	}
}
