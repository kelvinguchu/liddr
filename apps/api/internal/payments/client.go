package payments

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	requestTimeout  = 15 * time.Second
	tokenLifetime   = 55 * time.Minute
	maxResponseSize = 64 << 10
	processingCode  = "500.001.1001"
)

// ErrRejected reports that Daraja definitely refused a request, so no prompt
// reached the customer. Any other error leaves the outcome unknown.
var ErrRejected = errors.New("m-pesa request rejected")

var nairobi = time.FixedZone("EAT", 3*60*60)

// Config holds Daraja credentials.
type Config struct {
	BaseURL         string
	ConsumerKey     string
	ConsumerSecret  string
	Shortcode       string
	Passkey         string
	TransactionType string
}

// Client is a Daraja API client.
type Client struct {
	cfg  Config
	http *http.Client
	now  func() time.Time

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

// NewClient returns a Client using cfg.
func NewClient(cfg Config, now func() time.Time) *Client {
	cfg.BaseURL = strings.TrimRight(cfg.BaseURL, "/")
	return &Client{cfg: cfg, http: &http.Client{Timeout: requestTimeout}, now: now}
}

func (c *Client) cachedToken() (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.token, c.token != "" && c.now().Before(c.tokenExp)
}

// accessToken caches for most of the token's life. Concurrent misses each fetch
// one, which is harmless, so that no lock is held across the network call.
func (c *Client) accessToken(ctx context.Context) (string, error) {
	if token, ok := c.cachedToken(); ok {
		return token, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.cfg.BaseURL+"/oauth/v1/generate?grant_type=client_credentials", nil)
	if err != nil {
		return "", errors.New("build token request")
	}
	req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(c.cfg.ConsumerKey+":"+c.cfg.ConsumerSecret)))
	status, body, err := c.do(req)
	if err != nil {
		return "", fmt.Errorf("fetch access token: %w", err)
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
	}
	if status != http.StatusOK || json.Unmarshal(body, &parsed) != nil || parsed.AccessToken == "" {
		return "", fmt.Errorf("fetch access token: status %d", status)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.token = parsed.AccessToken
	c.tokenExp = c.now().Add(tokenLifetime)
	return parsed.AccessToken, nil
}

func (c *Client) do(req *http.Request) (int, []byte, error) {
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer func() {
		// The response has been fully handled by the time this runs.
		_ = resp.Body.Close()
	}()
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxResponseSize))
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("read response: %w", err)
	}
	return resp.StatusCode, body, nil
}

func (c *Client) postJSON(ctx context.Context, path string, payload any) (int, []byte, error) {
	token, err := c.accessToken(ctx)
	if err != nil {
		return 0, nil, err
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, fmt.Errorf("encode request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.cfg.BaseURL+path, bytes.NewReader(encoded))
	if err != nil {
		return 0, nil, errors.New("build request")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	return c.do(req)
}

func (c *Client) stkPassword(timestamp string) string {
	return base64.StdEncoding.EncodeToString([]byte(c.cfg.Shortcode + c.cfg.Passkey + timestamp))
}

func (c *Client) timestamp() string {
	return c.now().In(nairobi).Format("20060102150405")
}

// STKRequest describes a payment prompt.
type STKRequest struct {
	AmountKES        int32
	Phone            string
	CallbackURL      string
	AccountReference string
	Description      string
}

// STKResponse holds the identifiers Daraja will quote in its callback.
type STKResponse struct {
	MerchantRequestID string
	CheckoutRequestID string
}

// InitiateSTK sends a payment prompt to the customer's phone. Errors never
// include the phone number or the response body.
func (c *Client) InitiateSTK(ctx context.Context, in STKRequest) (STKResponse, error) {
	timestamp := c.timestamp()
	status, body, err := c.postJSON(ctx, "/mpesa/stkpush/v1/processrequest", map[string]any{
		"BusinessShortCode": c.cfg.Shortcode,
		"Password":          c.stkPassword(timestamp),
		"Timestamp":         timestamp,
		"TransactionType":   c.cfg.TransactionType,
		"Amount":            in.AmountKES,
		"PartyA":            in.Phone,
		"PartyB":            c.cfg.Shortcode,
		"PhoneNumber":       in.Phone,
		"CallBackURL":       in.CallbackURL,
		"AccountReference":  in.AccountReference,
		"TransactionDesc":   in.Description,
	})
	if err != nil {
		return STKResponse{}, fmt.Errorf("stk push: %w", err)
	}
	if status >= 400 && status < 500 {
		return STKResponse{}, fmt.Errorf("%w: status %d", ErrRejected, status)
	}
	if status < 200 || status > 299 {
		return STKResponse{}, fmt.Errorf("stk push: status %d", status)
	}

	var parsed struct {
		ResponseCode      flexValue `json:"ResponseCode"`
		MerchantRequestID string    `json:"MerchantRequestID"`
		CheckoutRequestID string    `json:"CheckoutRequestID"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return STKResponse{}, errors.New("stk push: unreadable response")
	}
	if parsed.ResponseCode != "0" {
		return STKResponse{}, fmt.Errorf("%w: response code %s", ErrRejected, parsed.ResponseCode)
	}
	if parsed.CheckoutRequestID == "" {
		return STKResponse{}, errors.New("stk push: response has no checkout id")
	}
	return STKResponse{MerchantRequestID: parsed.MerchantRequestID, CheckoutRequestID: parsed.CheckoutRequestID}, nil
}

// QueryResult is the state of an STK push.
type QueryResult struct {
	Pending    bool
	ResultCode int32
	ResultDesc string
}

// QuerySTK asks Daraja for the outcome of an STK push.
func (c *Client) QuerySTK(ctx context.Context, checkoutRequestID string) (QueryResult, error) {
	timestamp := c.timestamp()
	status, body, err := c.postJSON(ctx, "/mpesa/stkpushquery/v1/query", map[string]string{
		"BusinessShortCode": c.cfg.Shortcode,
		"Password":          c.stkPassword(timestamp),
		"Timestamp":         timestamp,
		"CheckoutRequestID": checkoutRequestID,
	})
	if err != nil {
		return QueryResult{}, fmt.Errorf("stk query: %w", err)
	}

	var parsed struct {
		ErrorCode  string    `json:"errorCode"`
		ResultCode flexValue `json:"ResultCode"`
		ResultDesc string    `json:"ResultDesc"`
	}
	decodeErr := json.Unmarshal(body, &parsed)
	if decodeErr == nil && parsed.ErrorCode == processingCode {
		return QueryResult{Pending: true}, nil
	}
	if status < 200 || status > 299 || decodeErr != nil {
		return QueryResult{}, fmt.Errorf("stk query: status %d", status)
	}
	code, err := strconv.ParseInt(string(parsed.ResultCode), 10, 32)
	if err != nil {
		return QueryResult{}, errors.New("stk query: unreadable result code")
	}
	if code == ResultProcessing {
		return QueryResult{Pending: true}, nil
	}
	return QueryResult{ResultCode: int32(code), ResultDesc: parsed.ResultDesc}, nil
}

// RegisterC2BURLs tells Daraja where to send paybill confirmations.
func (c *Client) RegisterC2BURLs(ctx context.Context, validationURL, confirmationURL string) error {
	status, _, err := c.postJSON(ctx, "/mpesa/c2b/v2/registerurl", map[string]string{
		"ShortCode":       c.cfg.Shortcode,
		"ResponseType":    "Completed",
		"ValidationURL":   validationURL,
		"ConfirmationURL": confirmationURL,
	})
	if err != nil {
		return fmt.Errorf("register c2b urls: %w", err)
	}
	if status < 200 || status > 299 {
		return fmt.Errorf("register c2b urls: status %d", status)
	}
	return nil
}
