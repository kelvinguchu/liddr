package storage

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func testClient(t *testing.T, base string) (*Client, *rsa.PublicKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	account, err := json.Marshal(map[string]string{
		"client_email": "signer@project.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	})
	if err != nil {
		t.Fatalf("marshal account: %v", err)
	}
	client, err := New(Config{
		BaseURL:            base,
		Bucket:             "private-bucket",
		ServiceAccountJSON: string(account),
		Now:                func() time.Time { return time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC) },
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return client, &key.PublicKey
}

// The canonical form is written out by hand from Google's V4 signing
// documentation, so that a mistake in the code cannot also be in the test.
func TestSignUploadSignsTheDocumentedCanonicalRequest(t *testing.T) {
	client, public := testClient(t, "https://storage.googleapis.com")
	upload, err := client.SignUpload("docs/a b/1.jpg", "image/jpeg", 1024, 10*time.Minute)
	if err != nil {
		t.Fatalf("SignUpload: %v", err)
	}
	if upload.Headers["content-type"] != "image/jpeg" || upload.Headers["x-goog-content-length-range"] != "0,1024" {
		t.Errorf("headers = %v", upload.Headers)
	}
	parsed, err := url.Parse(upload.URL)
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}
	if want := "/private-bucket/docs/a%20b/1.jpg"; parsed.EscapedPath() != want {
		t.Errorf("path = %s, want %s", parsed.EscapedPath(), want)
	}
	query := "X-Goog-Algorithm=GOOG4-RSA-SHA256" +
		"&X-Goog-Credential=signer%40project.iam.gserviceaccount.com%2F20260302%2Fauto%2Fstorage%2Fgoog4_request" +
		"&X-Goog-Date=20260302T090000Z&X-Goog-Expires=600" +
		"&X-Goog-SignedHeaders=content-type%3Bhost%3Bx-goog-content-length-range"
	canonical := "PUT\n/private-bucket/docs/a%20b/1.jpg\n" + query + "\n" +
		"content-type:image/jpeg\nhost:storage.googleapis.com\nx-goog-content-length-range:0,1024\n\n" +
		"content-type;host;x-goog-content-length-range\nUNSIGNED-PAYLOAD"
	hashed := sha256.Sum256([]byte(canonical))
	toSign := "GOOG4-RSA-SHA256\n20260302T090000Z\n20260302/auto/storage/goog4_request\n" + hex.EncodeToString(hashed[:])
	digest := sha256.Sum256([]byte(toSign))
	signature, err := hex.DecodeString(parsed.Query().Get("X-Goog-Signature"))
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	if err := rsa.VerifyPKCS1v15(public, crypto.SHA256, digest[:], signature); err != nil {
		t.Errorf("signature does not cover the documented request: %v", err)
	}
}

func TestStatAndRead(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/missing"):
			w.WriteHeader(http.StatusNotFound)
		case strings.HasSuffix(r.URL.Path, "/broken"):
			w.WriteHeader(http.StatusInternalServerError)
		default:
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("0123456789"))
		}
	}))
	defer server.Close()
	client, _ := testClient(t, server.URL)

	object, err := client.Stat(t.Context(), "present")
	if err != nil || object.ContentType != "image/png" || object.Size != 10 {
		t.Errorf("Stat = %+v, %v", object, err)
	}
	data, err := client.Read(t.Context(), "present", 10)
	if err != nil || string(data) != "0123456789" {
		t.Errorf("Read = %q, %v", data, err)
	}
	cases := []struct {
		name  string
		key   string
		limit int64
		want  error
	}{
		{"missing", "missing", 10, ErrNotFound},
		{"provider error", "broken", 10, ErrUnavailable},
		{"over the limit", "present", 9, ErrTooLarge},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := client.Read(t.Context(), tc.key, tc.limit); !errors.Is(err, tc.want) {
				t.Errorf("Read = %v, want %v", err, tc.want)
			}
		})
	}
}
