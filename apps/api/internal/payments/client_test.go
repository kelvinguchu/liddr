package payments

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

var fixedNow = time.Date(2026, 11, 9, 9, 0, 0, 0, time.UTC)

type daraja struct {
	tokenCalls atomic.Int32
	status     int
	body       string
	got        map[string]any
}

func (d *daraja) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/oauth") {
		d.tokenCalls.Add(1)
		_, _ = w.Write([]byte(`{"access_token":"tok","expires_in":"3599"}`))
		return
	}
	if r.Header.Get("Authorization") != "Bearer tok" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := json.NewDecoder(r.Body).Decode(&d.got); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(d.status)
	_, _ = w.Write([]byte(d.body))
}

func newClient(t *testing.T, d *daraja) *Client {
	t.Helper()
	server := httptest.NewServer(d)
	t.Cleanup(server.Close)
	return NewClient(Config{
		BaseURL: server.URL + "/", ConsumerKey: "key", ConsumerSecret: "secret",
		Shortcode: "174379", Passkey: "pass", TransactionType: "CustomerPayBillOnline",
	}, func() time.Time { return fixedNow })
}

var testSTK = STKRequest{AmountKES: 1000, Phone: "254712345678", CallbackURL: "https://x/cb", AccountReference: "LDR1", Description: "Weekly"}

func TestInitiateSTKSendsDarajaFields(t *testing.T) {
	d := &daraja{status: 200, body: `{"ResponseCode":"0","MerchantRequestID":"m","CheckoutRequestID":"c"}`}
	got, err := newClient(t, d).InitiateSTK(t.Context(), testSTK)
	if err != nil {
		t.Fatalf("InitiateSTK: %v", err)
	}
	if got.CheckoutRequestID != "c" || got.MerchantRequestID != "m" {
		t.Errorf("response = %+v", got)
	}
	// 09:00 UTC is 12:00 in Nairobi.
	const timestamp = "20261109120000"
	if d.got["Timestamp"] != timestamp {
		t.Errorf("Timestamp = %v", d.got["Timestamp"])
	}
	if want := base64.StdEncoding.EncodeToString([]byte("174379pass" + timestamp)); d.got["Password"] != want {
		t.Errorf("Password = %v, want %v", d.got["Password"], want)
	}
	if d.got["Amount"] != float64(1000) || d.got["PartyA"] != testSTK.Phone || d.got["PartyB"] != "174379" {
		t.Errorf("payload = %v", d.got)
	}
}

func TestInitiateSTKSeparatesRefusalFromUnknownOutcome(t *testing.T) {
	tests := []struct {
		name     string
		status   int
		body     string
		rejected bool
	}{
		{"validation error", 400, `{"errorCode":"400.002.02"}`, true},
		{"nonzero response code", 200, `{"ResponseCode":"1"}`, true},
		{"gateway error", 502, `bad gateway`, false},
		{"unreadable success", 200, `<html>`, false},
		{"missing checkout id", 200, `{"ResponseCode":"0"}`, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := newClient(t, &daraja{status: tt.status, body: tt.body}).InitiateSTK(t.Context(), testSTK)
			if err == nil {
				t.Fatal("InitiateSTK returned nil")
			}
			if got := errors.Is(err, ErrRejected); got != tt.rejected {
				t.Errorf("rejected = %v, want %v (%v)", got, tt.rejected, err)
			}
			if strings.Contains(err.Error(), testSTK.Phone) {
				t.Errorf("error leaked the phone: %v", err)
			}
		})
	}
}

func TestAccessTokenIsCached(t *testing.T) {
	d := &daraja{status: 200, body: `{"ResponseCode":"0","CheckoutRequestID":"c"}`}
	client := newClient(t, d)
	for range 3 {
		if _, err := client.InitiateSTK(t.Context(), testSTK); err != nil {
			t.Fatalf("InitiateSTK: %v", err)
		}
	}
	if got := d.tokenCalls.Load(); got != 1 {
		t.Errorf("token fetched %d times, want 1", got)
	}
}

func TestQuerySTK(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		want    QueryResult
		wantErr bool
	}{
		{name: "paid", status: 200, body: `{"ResultCode":"0","ResultDesc":"ok"}`, want: QueryResult{ResultDesc: "ok"}},
		{name: "cancelled", status: 200, body: `{"ResultCode":1032,"ResultDesc":"no"}`, want: QueryResult{ResultCode: 1032, ResultDesc: "no"}},
		{name: "still processing error", status: 500, body: `{"errorCode":"500.001.1001"}`, want: QueryResult{Pending: true}},
		{name: "still processing code", status: 200, body: `{"ResultCode":"4999"}`, want: QueryResult{Pending: true}},
		{name: "server error", status: 503, body: `oops`, wantErr: true},
		{name: "no result code", status: 200, body: `{}`, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := newClient(t, &daraja{status: tt.status, body: tt.body}).QuerySTK(t.Context(), "c")
			if tt.wantErr {
				if err == nil {
					t.Fatalf("QuerySTK = %+v, want error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("QuerySTK: %v", err)
			}
			if got != tt.want {
				t.Errorf("QuerySTK = %+v, want %+v", got, tt.want)
			}
		})
	}
}
