// Package storage reaches private objects in Google Cloud Storage through
// short-lived V4 signed URLs, so that no object is ever public.
package storage

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	algorithm     = "GOOG4-RSA-SHA256"
	requestScope  = "auto/storage/goog4_request"
	timeFormat    = "20060102T150405Z"
	headerLengths = "x-goog-content-length-range"
	httpTimeout   = 10 * time.Second
)

// Errors returned to callers.
var (
	ErrNotFound    = errors.New("object does not exist")
	ErrUnavailable = errors.New("storage request failed")
	ErrTooLarge    = errors.New("object is larger than allowed")
)

// Config holds the bucket and the service account that signs for it.
type Config struct {
	BaseURL            string
	Bucket             string
	ServiceAccountJSON string
	Now                func() time.Time
}

// Client signs URLs and inspects objects.
type Client struct {
	base   *url.URL
	bucket string
	email  string
	key    *rsa.PrivateKey
	now    func() time.Time
	http   *http.Client
}

// New parses the service account and returns a Client.
func New(cfg Config) (*Client, error) {
	base, err := url.Parse(cfg.BaseURL)
	if err != nil || base.Host == "" {
		return nil, errors.New("storage base URL is not valid")
	}
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
		base:   base,
		bucket: cfg.Bucket,
		email:  account.ClientEmail,
		key:    key,
		now:    cfg.Now,
		http:   &http.Client{Timeout: httpTimeout},
	}, nil
}

// escapePath encodes an object path as V4 signing requires, keeping slashes.
func escapePath(path string) string {
	segments := strings.Split(path, "/")
	for i, segment := range segments {
		segments[i] = rfc3986(segment)
	}
	return strings.Join(segments, "/")
}

// rfc3986 percent-encodes everything but unreserved characters. url.QueryEscape
// differs by writing spaces as plus, which would break the signature.
func rfc3986(value string) string {
	return strings.ReplaceAll(url.QueryEscape(value), "+", "%20")
}

// sign returns a URL valid for ttl. headers are the extra headers the eventual
// request must carry, which the signature binds it to.
func (c *Client) sign(method, key string, headers map[string]string, ttl time.Duration) (string, error) {
	now := c.now().UTC()
	stamp := now.Format(timeFormat)
	scope := stamp[:8] + "/" + requestScope

	all := map[string]string{"host": c.base.Host}
	for name, value := range headers {
		all[strings.ToLower(name)] = strings.TrimSpace(value)
	}
	names := make([]string, 0, len(all))
	for name := range all {
		names = append(names, name)
	}
	slices.Sort(names)
	var canonicalHeaders strings.Builder
	for _, name := range names {
		canonicalHeaders.WriteString(name + ":" + all[name] + "\n")
	}
	signedHeaders := strings.Join(names, ";")

	query := url.Values{
		"X-Goog-Algorithm":     {algorithm},
		"X-Goog-Credential":    {c.email + "/" + scope},
		"X-Goog-Date":          {stamp},
		"X-Goog-Expires":       {strconv.FormatInt(int64(ttl.Seconds()), 10)},
		"X-Goog-SignedHeaders": {signedHeaders},
	}
	canonicalQuery := strings.ReplaceAll(query.Encode(), "+", "%20")
	path := "/" + rfc3986(c.bucket) + "/" + escapePath(key)
	canonical := strings.Join([]string{
		method, path, canonicalQuery, canonicalHeaders.String(), signedHeaders, "UNSIGNED-PAYLOAD",
	}, "\n")

	hashed := sha256.Sum256([]byte(canonical))
	toSign := strings.Join([]string{algorithm, stamp, scope, hex.EncodeToString(hashed[:])}, "\n")
	digest := sha256.Sum256([]byte(toSign))
	signature, err := rsa.SignPKCS1v15(nil, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", fmt.Errorf("sign url: %w", err)
	}
	return c.base.Scheme + "://" + c.base.Host + path + "?" + canonicalQuery +
		"&X-Goog-Signature=" + hex.EncodeToString(signature), nil
}

// Upload is a URL the client can PUT one object to.
type Upload struct {
	URL     string
	Headers map[string]string
}

// SignUpload allows one PUT of an object no larger than maxBytes.
func (c *Client) SignUpload(key, contentType string, maxBytes int64, ttl time.Duration) (Upload, error) {
	headers := map[string]string{
		"content-type": contentType,
		headerLengths:  "0," + strconv.FormatInt(maxBytes, 10),
	}
	signed, err := c.sign(http.MethodPut, key, headers, ttl)
	if err != nil {
		return Upload{}, err
	}
	return Upload{URL: signed, Headers: headers}, nil
}

// SignDownload allows reading an object for ttl.
func (c *Client) SignDownload(key string, ttl time.Duration) (string, error) {
	return c.sign(http.MethodGet, key, nil, ttl)
}

// Object describes a stored object.
type Object struct {
	Size        int64
	ContentType string
}

func (c *Client) do(ctx context.Context, method, key string) (*http.Response, error) {
	signed, err := c.sign(method, key, nil, time.Minute)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, method, signed, http.NoBody)
	if err != nil {
		return nil, fmt.Errorf("build storage request: %w", err)
	}
	resp, err := c.http.Do(req) //nolint:gosec // The URL is built from configuration and a server-generated key.
	if err != nil {
		return nil, errors.Join(ErrUnavailable, err)
	}
	switch resp.StatusCode {
	case http.StatusOK:
		return resp, nil
	case http.StatusNotFound:
		_ = resp.Body.Close() // Only the status mattered.
		return nil, ErrNotFound
	default:
		_ = resp.Body.Close() // Only the status mattered.
		return nil, fmt.Errorf("%w: status %d", ErrUnavailable, resp.StatusCode)
	}
}

// Stat reads an object's size and type without downloading it.
func (c *Client) Stat(ctx context.Context, key string) (Object, error) {
	resp, err := c.do(ctx, http.MethodHead, key)
	if err != nil {
		return Object{}, err
	}
	defer func() { _ = resp.Body.Close() }() // A HEAD response has no body to lose.
	return Object{Size: resp.ContentLength, ContentType: resp.Header.Get("Content-Type")}, nil
}

// Read downloads an object, refusing any larger than limit bytes.
func (c *Client) Read(ctx context.Context, key string, limit int64) ([]byte, error) {
	resp, err := c.do(ctx, http.MethodGet, key)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }() // Everything needed has been read.
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, errors.Join(ErrUnavailable, err)
	}
	if int64(len(data)) > limit {
		return nil, ErrTooLarge
	}
	return data, nil
}
