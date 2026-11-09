package auth

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

type googleFixture struct {
	key      *rsa.PrivateKey
	verifier *GoogleVerifier
	fetches  *atomic.Int32
	now      time.Time
}

func newGoogleFixture(t *testing.T) *googleFixture {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	f := &googleFixture{key: key, fetches: &atomic.Int32{}, now: time.Unix(1_800_000_000, 0)}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		f.fetches.Add(1)
		w.Header().Set("Cache-Control", "public, max-age=3600")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{
			"kid": "good", "kty": "RSA",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	t.Cleanup(server.Close)
	f.verifier = NewGoogleVerifier(server.URL, []string{"my-app"}, func() time.Time { return f.now })
	return f
}

func (f *googleFixture) token(t *testing.T, header, claims map[string]any, signer *rsa.PrivateKey) string {
	t.Helper()
	encode := func(v any) string {
		data, err := json.Marshal(v)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		return base64.RawURLEncoding.EncodeToString(data)
	}
	input := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(input))
	signature, err := rsa.SignPKCS1v15(rand.Reader, signer, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func (f *googleFixture) claims() map[string]any {
	return map[string]any{
		"iss": "https://accounts.google.com", "aud": "my-app", "sub": "123", "email": "A@B.com", "email_verified": "true",
		"exp": f.now.Add(time.Hour).Unix(), "iat": f.now.Add(-time.Minute).Unix(),
	}
}

func TestVerifyGoogleToken(t *testing.T) {
	f := newGoogleFixture(t)
	good := map[string]any{"alg": "RS256", "kid": "good"}
	identity, err := f.verifier.Verify(t.Context(), f.token(t, good, f.claims(), f.key))
	if err != nil || identity.Subject != "123" || identity.Email != "a@b.com" || !identity.EmailVerified {
		t.Fatalf("Verify = %+v, %v", identity, err)
	}

	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	with := func(key string, value any) map[string]any {
		c := f.claims()
		c[key] = value
		return c
	}
	cases := []struct {
		name   string
		header map[string]any
		claims map[string]any
		signer *rsa.PrivateKey
	}{
		{"signed by someone else", good, f.claims(), other},
		{"for another app", good, with("aud", "their-app"), f.key},
		{"from another issuer", good, with("iss", "https://evil.example"), f.key},
		{"expired", good, with("exp", f.now.Add(-2*time.Minute).Unix()), f.key},
		{"issued in the future", good, with("iat", f.now.Add(10*time.Minute).Unix()), f.key},
		{"no subject", good, with("sub", ""), f.key},
		{"weak algorithm", map[string]any{"alg": "none", "kid": "good"}, f.claims(), f.key},
		{"unknown key", map[string]any{"alg": "RS256", "kid": "bad"}, f.claims(), f.key},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := f.verifier.Verify(t.Context(), f.token(t, tc.header, tc.claims, tc.signer)); !errors.Is(err, ErrInvalidIDToken) {
				t.Errorf("Verify = %v", err)
			}
		})
	}
	if got := f.fetches.Load(); got != 1 {
		t.Errorf("key fetches = %d, want 1: bad tokens must not reach Google", got)
	}
}

func FuzzParseIDToken(f *testing.F) {
	f.Add("a.b.c")
	f.Add("")
	f.Add("eyJhbGciOiJSUzI1NiIsImtpZCI6IngifQ.e30.AA")
	f.Fuzz(func(t *testing.T, token string) {
		if _, err := parseIDToken(token); err != nil && !errors.Is(err, ErrInvalidIDToken) {
			t.Errorf("unexpected error %v", err)
		}
	})
}

func TestNormalizeEmail(t *testing.T) {
	cases := []struct {
		name, raw, want string
		ok              bool
	}{
		{"plain", "a@b.co", "a@b.co", true},
		{"spaces and capitals", "  A@B.Co ", "a@b.co", true},
		{"display name is refused", "Evil <a@b.co>", "", false},
		{"not an address", "nope", "", false},
		{"two addresses", "a@b.co,c@d.co", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeEmail(tc.raw)
			if (err == nil) != tc.ok || got != tc.want {
				t.Errorf("NormalizeEmail = %q, %v", got, err)
			}
		})
	}
}
