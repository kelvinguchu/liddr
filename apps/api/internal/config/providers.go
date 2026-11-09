package config

import (
	"encoding/base64"
	"fmt"
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
	Bucket         string
	BaseURL        string
	ServiceAccount Secret
	ClamAVAddr     string
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
