// Package email sends transactional mail through Resend.
package email

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	sendTimeout = 12 * time.Second
	maxResponse = 64 << 10
)

// ErrRejected reports that the provider refused the message.
var ErrRejected = errors.New("email provider rejected message")

// Config holds Resend settings.
type Config struct {
	URL    string
	APIKey string
	From   string
}

// Client is a Resend API client.
type Client struct {
	cfg  Config
	http *http.Client
}

// New returns a Client using cfg.
func New(cfg Config) *Client {
	return &Client{cfg: cfg, http: &http.Client{Timeout: sendTimeout}}
}

// Send delivers a plain-text email and returns nil only once it was accepted.
// Errors never include the address or the body, which holds a sign-in code.
func (c *Client) Send(ctx context.Context, to, subject, text string) error {
	body, err := json.Marshal(map[string]any{"from": c.cfg.From, "to": []string{to}, "subject": subject, "text": text})
	if err != nil {
		return errors.New("encode email")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.URL, bytes.NewReader(body))
	if err != nil {
		return errors.New("build email request")
	}
	req.Header.Set("Authorization", "Bearer "+c.cfg.APIKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req) //nolint:gosec // The URL comes from configuration.
	if err != nil {
		if urlErr, ok := errors.AsType[*url.Error](err); ok {
			return fmt.Errorf("send email: %w", urlErr.Err)
		}
		return fmt.Errorf("send email: %w", err)
	}
	defer func() { _ = resp.Body.Close() }() // The response is fully handled by then.
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("%w: http status %d", ErrRejected, resp.StatusCode)
	}
	var parsed struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponse)).Decode(&parsed); err != nil || parsed.ID == "" {
		return fmt.Errorf("%w: no message id", ErrRejected)
	}
	return nil
}
