// Package push sends Firebase Cloud Messaging data messages.
package push

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	scope       = "https://www.googleapis.com/auth/firebase.messaging"
	httpTimeout = 10 * time.Second
	tokenMargin = time.Minute
	assertTTL   = time.Hour
	maxBody     = 64 << 10
)

// Errors returned by Send.
var (
	// ErrUnregistered means this device token will never work again.
	ErrUnregistered = errors.New("device token is no longer registered")
	ErrUnavailable  = errors.New("push provider request failed")
)

// Config holds the Firebase project and the service account that sends for it.
type Config struct {
	BaseURL            string
	TokenURL           string
	ProjectID          string
	ServiceAccountJSON string
	Now                func() time.Time
}

// Client sends messages and caches its OAuth token.
type Client struct {
	baseURL, tokenURL, project, email string

	key  *rsa.PrivateKey
	now  func() time.Time
	http *http.Client

	mu      sync.Mutex
	token   string
	expires time.Time
}

// New parses the service account and returns a Client.
func New(cfg Config) (*Client, error) {
	var account struct {
		ClientEmail string `json:"client_email"`
		PrivateKey  string `json:"private_key"`
	}
	if err := json.Unmarshal([]byte(cfg.ServiceAccountJSON), &account); err != nil {
		return nil, errors.New("service account is not valid JSON")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil || account.ClientEmail == "" {
		return nil, errors.New("service account has no usable key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("service account key cannot be parsed")
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("service account key is not RSA")
	}
	return &Client{
		baseURL: strings.TrimRight(cfg.BaseURL, "/"), tokenURL: cfg.TokenURL, project: cfg.ProjectID,
		email: account.ClientEmail, key: key, now: cfg.Now, http: &http.Client{Timeout: httpTimeout},
	}, nil
}

// Message is one data message. Data must hold identifiers only, because it
// passes through Google and may be displayed on a locked screen by the client.
type Message struct {
	Token string
	Data  map[string]string
	TTL   time.Duration
}

// Send delivers one message.
func (c *Client) Send(ctx context.Context, m Message) error {
	access, err := c.accessToken(ctx)
	if err != nil {
		return err
	}
	var body bytes.Buffer
	err = json.NewEncoder(&body).Encode(map[string]any{"message": map[string]any{
		"token": m.Token,
		"data":  m.Data,
		"android": map[string]string{
			"priority": "high",
			"ttl":      fmt.Sprintf("%ds", int(m.TTL.Seconds())),
		},
	}})
	if err != nil {
		return fmt.Errorf("encode message: %w", err)
	}
	target := c.baseURL + "/v1/projects/" + url.PathEscape(c.project) + "/messages:send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, &body)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req) //nolint:gosec // The URL comes from configuration.
	if err != nil {
		return errors.Join(ErrUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }() // Everything needed has been read.
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	if resp.StatusCode == http.StatusUnauthorized {
		c.forgetToken()
	}
	return classify(resp)
}

// classify reads Google's structured error code rather than searching the text.
func classify(resp *http.Response) error {
	var failure struct {
		Error struct {
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBody))
	if err == nil && json.Unmarshal(data, &failure) == nil {
		for _, detail := range failure.Error.Details {
			if detail.ErrorCode == "UNREGISTERED" {
				return ErrUnregistered
			}
		}
	}
	return fmt.Errorf("%w: status %d", ErrUnavailable, resp.StatusCode)
}

func (c *Client) cached(now time.Time) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.token, c.token != "" && now.Before(c.expires)
}

func (c *Client) forgetToken() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.token = ""
}

// accessToken fetches outside the lock. Two callers may refresh at once, which
// costs one extra request and never blocks the others on the network.
func (c *Client) accessToken(ctx context.Context) (string, error) {
	now := c.now()
	if token, ok := c.cached(now); ok {
		return token, nil
	}
	assertion, err := c.assertion(now)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("build token request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req) //nolint:gosec // The URL comes from configuration.
	if err != nil {
		return "", errors.Join(ErrUnavailable, err)
	}
	defer func() { _ = resp.Body.Close() }() // Everything needed has been read.
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%w: token status %d", ErrUnavailable, resp.StatusCode)
	}
	var token struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(&token); err != nil || token.AccessToken == "" {
		return "", fmt.Errorf("%w: unreadable token response", ErrUnavailable)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.token, c.expires = token.AccessToken, now.Add(time.Duration(token.ExpiresIn)*time.Second-tokenMargin)
	return c.token, nil
}

func (c *Client) assertion(now time.Time) (string, error) {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, err := json.Marshal(map[string]any{
		"iss": c.email, "scope": scope, "aud": c.tokenURL,
		"iat": now.Unix(), "exp": now.Add(assertTTL).Unix(),
	})
	if err != nil {
		return "", fmt.Errorf("encode claims: %w", err)
	}
	input := header + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(input))
	signature, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign assertion: %w", err)
	}
	return input + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
