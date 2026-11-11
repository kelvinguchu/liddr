// Package sms sends text messages through Onfon Media's HTTP API.
package sms

import (
	"bytes"
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
	sendPath        = "/v1/sms/SendBulkSMS"
)

// ErrRejected reports that the provider refused the message.
var ErrRejected = errors.New("sms provider rejected message")

// Config holds Onfon credentials. BaseURL is the API's origin, such as
// https://api.onfonmedia.co.ke; the send path is added to it.
type Config struct {
	BaseURL   string
	APIKey    string
	ClientID  string
	AccessKey string
	SenderID  string
}

// Client is an Onfon API client.
type Client struct {
	cfg  Config
	http *http.Client
}

// NewClient returns a Client using cfg.
func NewClient(cfg Config) *Client {
	return &Client{cfg: cfg, http: &http.Client{Timeout: sendTimeout}}
}

type messageParameter struct {
	Number string `json:"Number"`
	Text   string `json:"Text"`
}

type sendRequest struct {
	APIKey            string             `json:"ApiKey"`
	ClientID          string             `json:"ClientId"`
	SenderID          string             `json:"SenderId"`
	MessageParameters []messageParameter `json:"MessageParameters"`
}

// Send delivers message to phone (254XXXXXXXXX), returning nil only when Onfon
// accepted it. Errors never include the phone number, the message, the
// credentials or the response body, because the provider can echo them and a
// sign-in code would then reach logs. They do carry Onfon's error code.
func (c *Client) Send(ctx context.Context, phone, message string) error {
	endpoint, err := c.endpoint()
	if err != nil {
		return err
	}
	// Onfon takes its credentials in the body, sent only to the configured
	// API over HTTPS; nothing here is logged.
	body, err := json.Marshal(sendRequest{ //nolint:gosec // The provider requires ApiKey and ClientId in the JSON body.
		APIKey:            c.cfg.APIKey,
		ClientID:          c.cfg.ClientID,
		SenderID:          c.cfg.SenderID,
		MessageParameters: []messageParameter{{Number: phone, Text: message}},
	})
	if err != nil {
		return errors.New("encode sms request")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return errors.New("build sms request")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("AccessKey", c.cfg.AccessKey)

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
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return fmt.Errorf("read sms response: %w", err)
	}
	return checkResponse(raw)
}

func (c *Client) endpoint() (string, error) {
	base, err := url.Parse(c.cfg.BaseURL)
	if err != nil || base.Host == "" {
		return "", errors.New("sms base url is not a url")
	}
	return base.JoinPath(sendPath).String(), nil
}

// checkResponse accepts only Onfon's success code. ErrorCode arrives as the
// number 0 or the string "000" depending on the endpoint version, and the key
// is sometimes lower camel case.
func checkResponse(body []byte) error {
	var parsed struct {
		ErrorCode      json.RawMessage `json:"ErrorCode"`
		LowerErrorCode json.RawMessage `json:"errorCode"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return fmt.Errorf("%w: response is not json", ErrRejected)
	}
	code := codeText(parsed.ErrorCode)
	if code == "" {
		code = codeText(parsed.LowerErrorCode)
	}
	switch {
	case code == "":
		return fmt.Errorf("%w: no error code in response", ErrRejected)
	case strings.Trim(code, "0") == "":
		return nil
	default:
		return fmt.Errorf("%w: onfon code %s", ErrRejected, code)
	}
}

// codeText returns an error code as digits, or "" when it is absent or not a
// code. Only digits pass, so nothing the provider echoes reaches an error.
func codeText(raw json.RawMessage) string {
	value := strings.Trim(string(raw), "\" \t\r\n")
	if value == "" || len(value) > 6 || strings.Trim(value, "0123456789") != "" {
		return ""
	}
	return value
}
