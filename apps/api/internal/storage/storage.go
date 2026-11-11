// Package storage reaches private objects in Cloudflare R2 through short-lived
// presigned URLs (AWS Signature Version 4, which R2 speaks), so that no object
// is ever public and the access key never leaves the server.
package storage

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
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
	algorithm   = "AWS4-HMAC-SHA256"
	region      = "auto"
	service     = "s3"
	timeFormat  = "20060102T150405Z"
	maxExpiry   = 7 * 24 * time.Hour
	httpTimeout = 10 * time.Second
)

// Errors returned to callers.
var (
	ErrNotFound    = errors.New("object does not exist")
	ErrUnavailable = errors.New("storage request failed")
	ErrTooLarge    = errors.New("object is larger than allowed")
)

// Config holds the bucket and the R2 API token that signs for it. Endpoint is
// the account's S3 endpoint, https://<account id>.r2.cloudflarestorage.com.
type Config struct {
	Endpoint        string
	Bucket          string
	AccessKeyID     string
	SecretAccessKey string
	Now             func() time.Time
}

// Client signs URLs and inspects objects.
type Client struct {
	base      *url.URL
	bucket    string
	accessKey string
	secret    string
	now       func() time.Time
	http      *http.Client
}

// New checks the configuration and returns a Client.
func New(cfg Config) (*Client, error) {
	base, err := url.Parse(cfg.Endpoint)
	if err != nil || base.Host == "" || (base.Scheme != "https" && base.Scheme != "http") {
		return nil, errors.New("storage endpoint is not valid")
	}
	if cfg.Bucket == "" || cfg.AccessKeyID == "" || cfg.SecretAccessKey == "" {
		return nil, errors.New("storage needs a bucket, an access key ID and a secret")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return &Client{
		base:      base,
		bucket:    cfg.Bucket,
		accessKey: cfg.AccessKeyID,
		secret:    cfg.SecretAccessKey,
		now:       now,
		http:      &http.Client{Timeout: httpTimeout},
	}, nil
}

// escapePath encodes an object path as Signature V4 requires, keeping slashes.
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

// presign is one request to sign. path is already escaped; headers are the
// extra headers, lower case, that the eventual request must carry.
type presign struct {
	method, host, path string
	region             string
	headers            map[string]string
	accessKey, secret  string
	at                 time.Time
	ttl                time.Duration
}

func hmacSHA256(key []byte, data string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(data)) // A hash never returns an error from Write.
	return mac.Sum(nil)
}

// url returns the presigned URL, following the Signature Version 4
// query-string steps: canonical request, string to sign, derived key.
func (p presign) url(scheme string) string {
	stamp := p.at.UTC().Format(timeFormat)
	day := stamp[:8]
	scope := day + "/" + p.region + "/" + service + "/aws4_request"

	all := map[string]string{"host": p.host}
	for name, value := range p.headers {
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
		"X-Amz-Algorithm":     {algorithm},
		"X-Amz-Credential":    {p.accessKey + "/" + scope},
		"X-Amz-Date":          {stamp},
		"X-Amz-Expires":       {strconv.FormatInt(int64(p.ttl.Seconds()), 10)},
		"X-Amz-SignedHeaders": {signedHeaders},
	}
	canonicalQuery := strings.ReplaceAll(query.Encode(), "+", "%20")
	canonical := strings.Join([]string{
		p.method, p.path, canonicalQuery, canonicalHeaders.String(), signedHeaders, "UNSIGNED-PAYLOAD",
	}, "\n")
	hashed := sha256.Sum256([]byte(canonical))
	toSign := strings.Join([]string{algorithm, stamp, scope, hex.EncodeToString(hashed[:])}, "\n")

	key := hmacSHA256([]byte("AWS4"+p.secret), day)
	key = hmacSHA256(key, p.region)
	key = hmacSHA256(key, service)
	key = hmacSHA256(key, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(key, toSign))

	return scheme + "://" + p.host + p.path + "?" + canonicalQuery + "&X-Amz-Signature=" + signature
}

// sign returns a URL for one object, valid for ttl, bound to headers.
func (c *Client) sign(method, key string, headers map[string]string, ttl time.Duration) (string, error) {
	if ttl <= 0 || ttl > maxExpiry {
		return "", fmt.Errorf("sign url: expiry must be within %s", maxExpiry)
	}
	return presign{
		method:    method,
		host:      c.base.Host,
		path:      "/" + rfc3986(c.bucket) + "/" + escapePath(key),
		region:    region,
		headers:   headers,
		accessKey: c.accessKey,
		secret:    c.secret,
		at:        c.now(),
		ttl:       ttl,
	}.url(c.base.Scheme), nil
}

// Upload is a URL the client can PUT one object to, with the headers it must send.
type Upload struct {
	URL     string
	Headers map[string]string
}

// SignUpload allows one PUT of an object of exactly size bytes and the given
// type. R2 cannot cap a size range the way some stores can, so the exact size
// the app declared is signed, and the object is checked again before use.
func (c *Client) SignUpload(key, contentType string, size int64, ttl time.Duration) (Upload, error) {
	headers := map[string]string{
		"content-type":   contentType,
		"content-length": strconv.FormatInt(size, 10),
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
		if urlErr, ok := errors.AsType[*url.Error](err); ok {
			// url.Error holds the signed URL. Keep only the cause.
			err = urlErr.Err
		}
		return nil, errors.Join(ErrUnavailable, err)
	}
	switch resp.StatusCode {
	case http.StatusOK, http.StatusNoContent:
		return resp, nil
	case http.StatusNotFound:
		_ = resp.Body.Close() // Only the status mattered.
		return nil, ErrNotFound
	default:
		_ = resp.Body.Close() // Only the status mattered.
		return nil, fmt.Errorf("%w: status %d", ErrUnavailable, resp.StatusCode)
	}
}

// Delete removes an object. Deleting a missing object succeeds in R2, as in S3.
func (c *Client) Delete(ctx context.Context, key string) error {
	resp, err := c.do(ctx, http.MethodDelete, key)
	if err != nil {
		return err
	}
	return resp.Body.Close()
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
