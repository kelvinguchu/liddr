// Package config reads process configuration from the environment.
package config

import (
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const redacted = "[redacted]"

// Secret holds a sensitive string and redacts itself in logs and formatting.
type Secret string

// Reveal returns the underlying value for the one call that needs it.
func (s Secret) Reveal() string { return string(s) }

// String redacts the value so that %v and %s cannot print it.
func (Secret) String() string { return redacted }

// GoString redacts the value so that %#v cannot print it.
func (Secret) GoString() string { return redacted }

// LogValue redacts the value in structured logs.
func (Secret) LogValue() slog.Value { return slog.StringValue(redacted) }

const (
	minHMACKeyBytes = 32
	dataKeyBytes    = 32
)

// SMS holds Onfon credentials.
type SMS struct {
	BaseURL   string
	APIKey    Secret
	ClientID  Secret
	AccessKey Secret
	SenderID  string
}

// Mpesa holds Daraja settings.
type Mpesa struct {
	BaseURL         string
	ConsumerKey     Secret
	ConsumerSecret  Secret
	Shortcode       string
	Passkey         Secret
	TransactionType string
	CallbackBaseURL string
	CallbackToken   Secret
	AllowedIPs      []netip.Addr
}

// Config is the validated configuration of the API server.
type Config struct {
	Addr             string
	DatabaseURL      Secret
	DBMaxConns       int32
	DrainDelay       time.Duration
	ShutdownTimeout  time.Duration
	TrustedProxyHops int
	AuthHMACKey      Secret
	DataKey          Secret
	OpsAllowedNets   []netip.Prefix
	// OpsConsoleOrigin is the staff console's exact origin. Set, staff can
	// sign in there with a session cookie; empty, cookie sign-in is off.
	OpsConsoleOrigin string
	Documents        Documents
	Push             Push
	Email            Email
	GoogleClientIDs  []string
	GoogleCertsURL   string
	SMS              SMS
	GoogleMapsKey    Secret
	GoogleRoutesURL  string
	Mpesa            Mpesa
	RealtimeOrigins  []string
}

// LoadDatabaseURL returns the only setting that migrations need. It may refer
// to other settings as ${NAME}, as in
// postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@host/${POSTGRES_DB}, so
// the database container and the API share one set of credentials whatever
// loads the environment.
func LoadDatabaseURL(getenv func(string) string) (Secret, error) {
	raw := getenv("DATABASE_URL")
	if raw == "" {
		return "", errors.New("DATABASE_URL is required")
	}
	expanded, missing := expandReferences(raw, getenv)
	if len(missing) > 0 {
		return "", fmt.Errorf("DATABASE_URL refers to unset %s", strings.Join(missing, ", "))
	}
	return Secret(expanded), nil
}

// Load validates the environment and reports every problem at once. Errors
// name the variable and never include its value.
func Load(getenv func(string) string) (Config, error) {
	var errs []error
	required := func(name string) string {
		value := getenv(name)
		if value == "" {
			errs = append(errs, fmt.Errorf("%s is required", name))
		}
		return value
	}

	cfg := Config{
		Addr:            withDefault(getenv("ADDR"), ":8080"),
		DatabaseURL:     loadDatabaseURL(getenv, &errs),
		AuthHMACKey:     Secret(required("AUTH_HMAC_KEY")),
		DataKey:         decodeDataKey(required("DATA_ENCRYPTION_KEY"), &errs),
		GoogleMapsKey:   Secret(required("GOOGLE_MAPS_API_KEY_SERVER")),
		GoogleRoutesURL: withDefault(getenv("GOOGLE_ROUTES_BASE_URL"), "https://routes.googleapis.com"),
		SMS: SMS{
			BaseURL:   withDefault(getenv("ONFON_API_URL"), "https://api.onfonmedia.co.ke"),
			APIKey:    Secret(required("ONFON_API_KEY")),
			ClientID:  Secret(required("ONFON_CLIENT_ID")),
			AccessKey: Secret(required("ONFON_ACCESS_KEY")),
			SenderID:  required("ONFON_SENDER_ID"),
		},
	}
	for origin := range strings.SplitSeq(getenv("REALTIME_ALLOWED_ORIGINS"), ",") {
		if origin = strings.TrimSpace(origin); origin != "" {
			if origin == "*" {
				errs = append(errs, errors.New("REALTIME_ALLOWED_ORIGINS must list exact origins"))
				continue
			}
			cfg.RealtimeOrigins = append(cfg.RealtimeOrigins, origin)
		}
	}
	shortcode, passkey := getenv("MPESA_SHORTCODE"), getenv("MPESA_PASSKEY")
	if getenv("MPESA_ENV") == "production" {
		shortcode, passkey = required("MPESA_SHORTCODE"), required("MPESA_PASSKEY")
	} else {
		// Sandbox has one public test till; the Daraja app's own values are
		// only for production.
		shortcode, passkey = withDefault(shortcode, sandboxShortcode), withDefault(passkey, string(sandboxPasskey))
	}
	cfg.Mpesa = Mpesa{
		BaseURL:         withDefault(getenv("MPESA_BASE_URL"), mpesaBaseURL(getenv("MPESA_ENV"))),
		ConsumerKey:     Secret(required("MPESA_CONSUMER_KEY")),
		ConsumerSecret:  Secret(required("MPESA_CONSUMER_SECRET")),
		Shortcode:       shortcode,
		Passkey:         Secret(passkey),
		TransactionType: withDefault(getenv("MPESA_STK_TRANSACTION_TYPE"), "CustomerPayBillOnline"),
		CallbackBaseURL: required("MPESA_CALLBACK_BASE_URL"),
		CallbackToken:   Secret(required("MPESA_CALLBACK_TOKEN")),
	}
	if cfg.Mpesa.CallbackToken != "" && len(cfg.Mpesa.CallbackToken) < minHMACKeyBytes {
		errs = append(errs, fmt.Errorf("MPESA_CALLBACK_TOKEN must be at least %d bytes", minHMACKeyBytes))
	}
	if strings.ContainsAny(string(cfg.Mpesa.CallbackToken), "/?#% ") {
		errs = append(errs, errors.New("MPESA_CALLBACK_TOKEN must be safe to place in a URL path"))
	}
	for field := range strings.SplitSeq(getenv("MPESA_CALLBACK_ALLOWED_IPS"), ",") {
		if field = strings.TrimSpace(field); field == "" {
			continue
		}
		addr, err := netip.ParseAddr(field)
		if err != nil {
			errs = append(errs, errors.New("MPESA_CALLBACK_ALLOWED_IPS must be comma-separated IP addresses"))
			continue
		}
		cfg.Mpesa.AllowedIPs = append(cfg.Mpesa.AllowedIPs, addr.Unmap())
	}
	if cfg.AuthHMACKey != "" && len(cfg.AuthHMACKey) < minHMACKeyBytes {
		errs = append(errs, fmt.Errorf("AUTH_HMAC_KEY must be at least %d bytes", minHMACKeyBytes))
	}

	for field := range strings.SplitSeq(getenv("OPS_ALLOWED_CIDRS"), ",") {
		if field = strings.TrimSpace(field); field == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(field)
		if err != nil {
			errs = append(errs, errors.New("OPS_ALLOWED_CIDRS must be comma-separated CIDR ranges"))
			continue
		}
		cfg.OpsAllowedNets = append(cfg.OpsAllowedNets, prefix.Masked())
	}

	if origin := strings.TrimSpace(getenv("OPS_CONSOLE_ORIGIN")); origin != "" {
		if !isOrigin(origin) {
			errs = append(errs, errors.New("OPS_CONSOLE_ORIGIN must be an exact origin, such as https://ops.example.com"))
		}
		cfg.OpsConsoleOrigin = origin
	}

	cfg.Documents = Documents{
		Bucket:          getenv("R2_BUCKET"),
		Endpoint:        getenv("R2_ENDPOINT"),
		AccessKeyID:     Secret(getenv("R2_ACCESS_KEY_ID")),
		SecretAccessKey: Secret(getenv("R2_SECRET_ACCESS_KEY")),
		ClamAVAddr:      getenv("CLAMAV_ADDR"),
	}
	if cfg.Documents.Bucket != "" {
		errs = append(errs, documentErrors(&cfg.Documents, getenv("R2_ACCOUNT_ID"))...)
	}

	cfg.Push = Push{
		ProjectID:      getenv("FCM_PROJECT_ID"),
		ServiceAccount: Secret(getenv("FCM_SERVICE_ACCOUNT_JSON")),
		BaseURL:        withDefault(getenv("FCM_BASE_URL"), "https://fcm.googleapis.com"),
		TokenURL:       withDefault(getenv("GOOGLE_TOKEN_URL"), "https://oauth2.googleapis.com/token"),
	}
	if cfg.Push.ProjectID != "" && cfg.Push.ServiceAccount == "" {
		errs = append(errs, errors.New("FCM_SERVICE_ACCOUNT_JSON is required with FCM_PROJECT_ID"))
	}

	cfg.Email = Email{URL: withDefault(getenv("RESEND_API_URL"), "https://api.resend.com/emails"), APIKey: Secret(getenv("RESEND_API_KEY")), From: getenv("OTP_EMAIL_FROM")}
	if cfg.Email.APIKey != "" && cfg.Email.From == "" {
		errs = append(errs, errors.New("OTP_EMAIL_FROM is required with RESEND_API_KEY"))
	}
	cfg.GoogleCertsURL = withDefault(getenv("GOOGLE_CERTS_URL"), "https://www.googleapis.com/oauth2/v3/certs")
	for id := range strings.SplitSeq(getenv("GOOGLE_CLIENT_IDS"), ",") {
		if id = strings.TrimSpace(id); id != "" {
			cfg.GoogleClientIDs = append(cfg.GoogleClientIDs, id)
		}
	}

	hops, err := strconv.Atoi(withDefault(getenv("TRUSTED_PROXY_HOPS"), "0"))
	if err != nil || hops < 0 {
		errs = append(errs, errors.New("TRUSTED_PROXY_HOPS must be a non-negative integer"))
	}
	cfg.TrustedProxyHops = hops

	maxConns, err := strconv.ParseInt(withDefault(getenv("DB_MAX_CONNS"), "20"), 10, 32)
	if err != nil || maxConns < 1 {
		errs = append(errs, errors.New("DB_MAX_CONNS must be a positive integer"))
	}
	cfg.DBMaxConns = int32(maxConns) //nolint:gosec // ParseInt bounded this to 32 bits.

	cfg.DrainDelay, err = parseDuration(getenv, "SHUTDOWN_DRAIN_DELAY", "5s")
	errs = append(errs, err)
	cfg.ShutdownTimeout, err = parseDuration(getenv, "SHUTDOWN_TIMEOUT", "20s")
	errs = append(errs, err)

	if err := errors.Join(errs...); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// isOrigin reports whether value is scheme://host[:port] and nothing more.
func isOrigin(value string) bool {
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return false
	}
	return u.User == nil && u.Path == "" && u.RawQuery == "" && u.Fragment == "" && u.Opaque == ""
}
