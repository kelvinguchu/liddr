package auth

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	googleCertsTimeout  = 5 * time.Second
	googleCertsDefault  = time.Hour
	googleRefreshMinGap = time.Minute
	googleClockSkew     = time.Minute
	maxGoogleResponse   = 256 << 10
	maxIDTokenBytes     = 8 << 10
)

var (
	googleIssuers = []string{"accounts.google.com", "https://accounts.google.com"}
	maxAgePattern = regexp.MustCompile(`max-age=(\d+)`)

	// ErrInvalidIDToken reports a token that did not prove a Google identity.
	ErrInvalidIDToken = errors.New("google sign-in could not be verified")
	// ErrGoogleUnavailable reports that Google's keys could not be fetched or
	// that sign-in with Google is not configured.
	ErrGoogleUnavailable = errors.New("google sign-in is unavailable")
)

// GoogleIdentity is what a verified ID token proves.
type GoogleIdentity struct {
	Subject       string
	Email         string
	EmailVerified bool
}

// GoogleVerifier checks ID tokens against Google's published keys. It verifies
// the signature itself, so that a sign-in does not wait on a call to Google.
type GoogleVerifier struct {
	certsURL  string
	clientIDs []string
	now       func() time.Time
	http      *http.Client

	mu        sync.Mutex
	keys      map[string]*rsa.PublicKey
	expires   time.Time
	fetchedAt time.Time
}

// NewGoogleVerifier returns a verifier accepting tokens issued to clientIDs.
func NewGoogleVerifier(certsURL string, clientIDs []string, now func() time.Time) *GoogleVerifier {
	return &GoogleVerifier{certsURL: certsURL, clientIDs: clientIDs, now: now, http: &http.Client{Timeout: googleCertsTimeout}}
}

type idTokenClaims struct {
	Issuer        string          `json:"iss"`
	Audience      string          `json:"aud"`
	Subject       string          `json:"sub"`
	Expires       int64           `json:"exp"`
	IssuedAt      int64           `json:"iat"`
	Email         string          `json:"email"`
	EmailVerified json.RawMessage `json:"email_verified"`
}

type parsedIDToken struct {
	kid       string
	signed    string
	signature []byte
	claims    idTokenClaims
}

// parseIDToken decodes a token without trusting anything in it.
func parseIDToken(token string) (parsedIDToken, error) {
	if len(token) > maxIDTokenBytes {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	// The algorithm is fixed here, so a token cannot choose a weaker one.
	if json.Unmarshal(headerJSON, &header) != nil || header.Alg != "RS256" || header.Kid == "" {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	claimsJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	var claims idTokenClaims
	if json.Unmarshal(claimsJSON, &claims) != nil {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return parsedIDToken{}, ErrInvalidIDToken
	}
	return parsedIDToken{kid: header.Kid, signed: parts[0] + "." + parts[1], signature: signature, claims: claims}, nil
}

// Verify proves a token came from Google, for this app, and has not expired.
func (v *GoogleVerifier) Verify(ctx context.Context, token string) (GoogleIdentity, error) {
	parsed, err := parseIDToken(token)
	if err != nil {
		return GoogleIdentity{}, err
	}
	key, err := v.key(ctx, parsed.kid)
	if err != nil {
		return GoogleIdentity{}, err
	}
	digest := sha256.Sum256([]byte(parsed.signed))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], parsed.signature) != nil {
		return GoogleIdentity{}, ErrInvalidIDToken
	}
	c := parsed.claims
	now := v.now()
	switch {
	case !slices.Contains(googleIssuers, c.Issuer),
		!slices.Contains(v.clientIDs, c.Audience),
		c.Subject == "",
		!now.Before(time.Unix(c.Expires, 0).Add(googleClockSkew)),
		now.Add(googleClockSkew).Before(time.Unix(c.IssuedAt, 0)):
		return GoogleIdentity{}, ErrInvalidIDToken
	}
	// Google sends this as a boolean or as the string "true".
	verified := string(c.EmailVerified) == "true" || string(c.EmailVerified) == `"true"`
	return GoogleIdentity{Subject: c.Subject, Email: strings.ToLower(strings.TrimSpace(c.Email)), EmailVerified: verified}, nil
}

func (v *GoogleVerifier) cachedKey(kid string, now time.Time) (key *rsa.PublicKey, fresh, mayFetch bool) {
	v.mu.Lock()
	defer v.mu.Unlock()
	key = v.keys[kid]
	return key, now.Before(v.expires), now.Sub(v.fetchedAt) >= googleRefreshMinGap
}

// key returns a signing key. An unknown key is fetched at most once a minute,
// so that tokens with invented key ids cannot make this server hammer Google.
func (v *GoogleVerifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	now := v.now()
	key, fresh, mayFetch := v.cachedKey(kid, now)
	if key != nil && fresh {
		return key, nil
	}
	if !mayFetch {
		if key != nil {
			return key, nil
		}
		return nil, ErrInvalidIDToken
	}
	if err := v.refresh(ctx, now); err != nil {
		return nil, err
	}
	key, _, _ = v.cachedKey(kid, now)
	if key == nil {
		return nil, ErrInvalidIDToken
	}
	return key, nil
}

func (v *GoogleVerifier) refresh(ctx context.Context, now time.Time) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.certsURL, http.NoBody)
	if err != nil {
		return fmt.Errorf("build certs request: %w", err)
	}
	resp, err := v.http.Do(req) //nolint:gosec // The URL comes from configuration.
	if err != nil {
		return errors.Join(ErrGoogleUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }() // The body has been read by then.
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: status %d", ErrGoogleUnavailable, resp.StatusCode)
	}
	var set struct {
		Keys []struct {
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxGoogleResponse)).Decode(&set); err != nil {
		return errors.Join(ErrGoogleUnavailable, err)
	}
	keys := make(map[string]*rsa.PublicKey, len(set.Keys))
	for _, k := range set.Keys {
		modulus, errN := base64.RawURLEncoding.DecodeString(k.N)
		exponent, errE := base64.RawURLEncoding.DecodeString(k.E)
		if k.Kty != "RSA" || errN != nil || errE != nil || len(exponent) > 4 {
			continue
		}
		keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(modulus), E: int(new(big.Int).SetBytes(exponent).Int64())}
	}
	ttl := googleCertsDefault
	if match := maxAgePattern.FindStringSubmatch(resp.Header.Get("Cache-Control")); match != nil {
		if seconds, err := strconv.Atoi(match[1]); err == nil {
			ttl = time.Duration(seconds) * time.Second
		}
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	v.keys, v.expires, v.fetchedAt = keys, now.Add(ttl), now
	return nil
}
