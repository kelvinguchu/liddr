package storage

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

var testNow = time.Date(2026, 3, 2, 9, 0, 0, 0, time.UTC)

func testClient(t *testing.T, endpoint string) *Client {
	t.Helper()
	client, err := New(Config{
		Endpoint:        endpoint,
		Bucket:          "private-bucket",
		AccessKeyID:     "access-key-id",
		SecretAccessKey: "secret-access-key",
		Now:             func() time.Time { return testNow },
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return client
}

// The expected signature is the one AWS publishes for this request in its
// Signature Version 4 query-string example (GET examplebucket/test.txt), so a
// mistake in the signer cannot also be in the test.
func TestPresignMatchesTheAWSDocumentedExample(t *testing.T) {
	got := presign{
		method:    http.MethodGet,
		host:      "examplebucket.s3.amazonaws.com",
		path:      "/test.txt",
		region:    "us-east-1",
		accessKey: "AKIAIOSFODNN7EXAMPLE",
		secret:    "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
		at:        time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC),
		ttl:       24 * time.Hour,
	}.url("https")
	want := "https://examplebucket.s3.amazonaws.com/test.txt" +
		"?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
		"&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host" +
		"&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
	if got != want {
		t.Errorf("presigned URL\n got %s\nwant %s", got, want)
	}
}

func TestSignUploadBindsTheExactSizeAndType(t *testing.T) {
	client := testClient(t, "https://account.r2.cloudflarestorage.com")
	upload, err := client.SignUpload("docs/a b/1.jpg", "image/jpeg", 1024, 10*time.Minute)
	if err != nil {
		t.Fatalf("SignUpload: %v", err)
	}
	if upload.Headers["content-type"] != "image/jpeg" || upload.Headers["content-length"] != "1024" || len(upload.Headers) != 2 {
		t.Errorf("headers = %v, want exactly content-type and content-length", upload.Headers)
	}
	parsed, err := url.Parse(upload.URL)
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}
	if parsed.Host != "account.r2.cloudflarestorage.com" || parsed.EscapedPath() != "/private-bucket/docs/a%20b/1.jpg" {
		t.Errorf("url = %s, want the bucket in the path on the account endpoint", upload.URL)
	}
	query := parsed.Query()
	for name, want := range map[string]string{
		"X-Amz-Credential":    "access-key-id/20260302/auto/s3/aws4_request",
		"X-Amz-Expires":       "600",
		"X-Amz-SignedHeaders": "content-length;content-type;host",
	} {
		if got := query.Get(name); got != want {
			t.Errorf("%s = %q, want %q", name, got, want)
		}
	}
	if strings.Contains(upload.URL, "secret-access-key") {
		t.Error("the URL carries the secret")
	}
}

func TestSignRefusesAnExpiryR2WillNotAccept(t *testing.T) {
	client := testClient(t, "https://account.r2.cloudflarestorage.com")
	if _, err := client.SignDownload("k", 8*24*time.Hour); err == nil {
		t.Error("SignDownload accepted an expiry beyond seven days")
	}
}

func TestNewRejectsIncompleteConfig(t *testing.T) {
	for name, cfg := range map[string]Config{
		"no endpoint": {Bucket: "b", AccessKeyID: "a", SecretAccessKey: "s"},
		"no bucket":   {Endpoint: "https://x.r2.cloudflarestorage.com", AccessKeyID: "a", SecretAccessKey: "s"},
		"no key":      {Endpoint: "https://x.r2.cloudflarestorage.com", Bucket: "b", SecretAccessKey: "s"},
		"no secret":   {Endpoint: "https://x.r2.cloudflarestorage.com", Bucket: "b", AccessKeyID: "a"},
	} {
		if _, err := New(cfg); err == nil {
			t.Errorf("%s: New accepted it", name)
		}
	}
}

func TestStatAndRead(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("X-Amz-Signature") == "" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
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
	client := testClient(t, server.URL)

	object, err := client.Stat(t.Context(), "present")
	if err != nil || object.ContentType != "image/png" || object.Size != 10 {
		t.Errorf("Stat = %+v, %v", object, err)
	}
	data, err := client.Read(t.Context(), "present", 10)
	if err != nil || string(data) != "0123456789" {
		t.Errorf("Read = %q, %v", data, err)
	}
	if err := client.Delete(t.Context(), "present"); err != nil {
		t.Errorf("Delete = %v", err)
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
