package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"time"
)

// Email configures Resend. An empty APIKey means email sign-in reports that it
// is unavailable.
type Email struct {
	URL    string
	APIKey Secret
	From   string
}

// Push configures Firebase. An empty ProjectID leaves notifications in the app
// inbox, and the server logs that at startup.
type Push struct {
	ProjectID      string
	ServiceAccount Secret
	BaseURL        string
	TokenURL       string
}

// Documents configures driver document storage. An empty Bucket means uploads
// are unavailable: the server starts, and upload routes report that they cannot
// serve. Once a bucket is set, the scanner and credentials are mandatory.
type Documents struct {
	Bucket string
	// Endpoint is the R2 account's S3 endpoint, built from R2_ACCOUNT_ID
	// unless R2_ENDPOINT overrides it (tests do).
	Endpoint        string
	AccessKeyID     Secret
	SecretAccessKey Secret
	ClamAVAddr      string
}

// r2AccountID is the 32-character hex ID Cloudflare gives each account.
var r2AccountID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// documentErrors completes and checks document storage once a bucket is set:
// the scanner and the R2 token are then mandatory.
func documentErrors(d *Documents, accountID string) []error {
	var errs []error
	if d.Endpoint == "" {
		if !r2AccountID.MatchString(accountID) {
			errs = append(errs, errors.New("R2_ACCOUNT_ID must be the 32-character Cloudflare account ID with R2_BUCKET"))
		}
		d.Endpoint = "https://" + accountID + ".r2.cloudflarestorage.com"
	}
	if d.AccessKeyID == "" || d.SecretAccessKey == "" {
		errs = append(errs, errors.New("R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY are required with R2_BUCKET"))
	}
	if d.ClamAVAddr == "" {
		errs = append(errs, errors.New("CLAMAV_ADDR is required with R2_BUCKET"))
	}
	return errs
}

// decodeDataKey expects standard base64 for exactly 32 random bytes.
func decodeDataKey(encoded string, errs *[]error) Secret {
	if encoded == "" {
		return ""
	}
	key, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(key) != dataKeyBytes {
		*errs = append(*errs, fmt.Errorf("DATA_ENCRYPTION_KEY must be base64 for %d bytes", dataKeyBytes))
		return ""
	}
	return Secret(key)
}

// Safaricom's public Daraja sandbox till and its Lipa na M-Pesa passkey, as
// published in the Daraja documentation. They work only against the sandbox.
const (
	sandboxShortcode        = "174379"
	sandboxPasskey   Secret = "bfb279f9aa9bdbcf158e97dd71a467cd2e0c893059b10f78e6b72ada1ed2c919" //nolint:gosec // Published by Safaricom for its sandbox; useless against production.
)

func loadDatabaseURL(getenv func(string) string, errs *[]error) Secret {
	url, err := LoadDatabaseURL(getenv)
	if err != nil {
		*errs = append(*errs, err)
	}
	return url
}

// reference is ${NAME}. A lone $ is left alone, since passwords may hold one.
var reference = regexp.MustCompile(`\$\{([A-Z_][A-Z0-9_]*)\}`)

// expandReferences replaces each ${NAME} with that setting and lists the names
// that are unset.
func expandReferences(value string, getenv func(string) string) (string, []string) {
	var missing []string
	expanded := reference.ReplaceAllStringFunc(value, func(match string) string {
		name := reference.FindStringSubmatch(match)[1]
		v := getenv(name)
		if v == "" && !slices.Contains(missing, name) {
			missing = append(missing, name)
		}
		return v
	})
	return expanded, missing
}

func mpesaBaseURL(environment string) string {
	if environment == "production" {
		return "https://api.safaricom.co.ke"
	}
	return "https://sandbox.safaricom.co.ke"
}

func parseDuration(getenv func(string) string, name, fallback string) (time.Duration, error) {
	d, err := time.ParseDuration(withDefault(getenv(name), fallback))
	if err != nil || d < 0 {
		return 0, fmt.Errorf("%s must be a non-negative duration", name)
	}
	return d, nil
}

func withDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
