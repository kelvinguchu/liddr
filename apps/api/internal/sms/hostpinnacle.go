// Package sms sends text messages through HostPinnacle.
package sms

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	sendTimeout     = 12 * time.Second
	maxResponseSize = 64 << 10
)

// ErrRejected reports that the provider refused the message.
var ErrRejected = errors.New("sms provider rejected message")

// Config holds HostPinnacle credentials.
type Config struct {
	URL      string
	APIKey   string
	UserID   string
	Password string
	SenderID string
}

// Client is a HostPinnacle API client.
type Client struct {
	cfg  Config
	http *http.Client
}

// NewClient returns a Client using cfg.
func NewClient(cfg Config) *Client {
	return &Client{cfg: cfg, http: &http.Client{Timeout: sendTimeout}}
}

// Send delivers message to phone, returning nil only when the provider accepted
// it. Errors never include the phone number, the message or the response body,
// because the provider can echo them and a sign-in code would then reach logs.
func (c *Client) Send(ctx context.Context, phone, message string) error {
	form := url.Values{
		"userid":         {c.cfg.UserID},
		"password":       {c.cfg.Password},
		"senderid":       {c.cfg.SenderID},
		"mobile":         {phone},
		"msg":            {message},
		"msgType":        {"text"},
		"duplicatecheck": {"true"},
		"output":         {"json"},
		"sendMethod":     {"quick"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.URL, strings.NewReader(form.Encode()))
	if err != nil {
		return errors.New("build sms request")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Cache-Control", "no-cache")
	req.Header.Set("apikey", c.cfg.APIKey)

	resp, err := c.http.Do(req)
	if err != nil {
		if urlErr, ok := errors.AsType[*url.Error](err); ok {
			// url.Error holds the request URL. Keep only the cause.
			return fmt.Errorf("send sms: %w", urlErr.Err)
		}
		return fmt.Errorf("send sms: %w", err)
	}
	defer func() {
		// The response has been fully handled by the time this runs.
		_ = resp.Body.Close()
	}()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("%w: http status %d", ErrRejected, resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return fmt.Errorf("read sms response: %w", err)
	}
	return checkResponse(body)
}

// checkResponse accepts the success shapes HostPinnacle is known to return.
// Fields are raw because the provider varies between strings and numbers.
func checkResponse(body []byte) error {
	var parsed struct {
		Status    json.RawMessage `json:"status"`
		Success   json.RawMessage `json:"success"`
		MsgID     json.RawMessage `json:"msgid"`
		MessageID json.RawMessage `json:"messageId"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return fmt.Errorf("%w: response is not json", ErrRejected)
	}

	status := text(parsed.Status)
	switch status {
	case "success", "ok", "sent":
		return nil
	case "":
		if text(parsed.Success) == "true" || text(parsed.MsgID) != "" || text(parsed.MessageID) != "" {
			return nil
		}
		return fmt.Errorf("%w: unrecognized response", ErrRejected)
	default:
		return fmt.Errorf("%w: unsuccessful status", ErrRejected)
	}
}

func text(raw json.RawMessage) string {
	value := strings.ToLower(strings.Trim(string(raw), "\" \t\r\n"))
	if value == "null" {
		return ""
	}
	return value
}
