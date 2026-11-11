package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // RFC 6238 authenticator apps use HMAC-SHA1.
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"time"

	"github.com/google/uuid"
)

const (
	totpPeriod      = 30
	totpSpan        = 1_000_000
	totpWindow      = 1
	totpSecretBytes = 20
)

var totpEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func newTOTPSecret() []byte {
	secret := make([]byte, totpSecretBytes)
	// crypto/rand.Read never returns an error; it aborts the program instead.
	_, _ = rand.Read(secret)
	return secret
}

func totpCounter(at time.Time) int64 {
	return at.Unix() / totpPeriod
}

func totpCode(secret []byte, counter int64) string {
	var message [8]byte
	binary.BigEndian.PutUint64(message[:], uint64(counter)) //nolint:gosec // Time counters are never negative.
	mac := hmac.New(sha1.New, secret)
	mac.Write(message[:])
	sum := mac.Sum(nil)
	offset := sum[len(sum)-1] & 0x0f
	value := binary.BigEndian.Uint32(sum[offset:offset+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", value%totpSpan)
}

// TOTPCode returns the code a correct authenticator shows at a moment, given
// the secret in the form it was handed to the user.
func TOTPCode(encodedSecret string, at time.Time) (string, error) {
	secret, err := totpEncoding.DecodeString(encodedSecret)
	if err != nil {
		return "", fmt.Errorf("decode secret: %w", err)
	}
	return totpCode(secret, totpCounter(at)), nil
}

// matchTOTP returns the counter a code belongs to, allowing for clock drift of
// one period each way. Every candidate is compared, so timing reveals nothing.
func matchTOTP(secret []byte, code string, at time.Time) (int64, bool) {
	current := totpCounter(at)
	matched, found := int64(0), false
	for offset := int64(-totpWindow); offset <= totpWindow; offset++ {
		if subtle.ConstantTimeCompare([]byte(totpCode(secret, current+offset)), []byte(code)) == 1 {
			matched, found = current+offset, true
		}
	}
	return matched, found
}

func totpURI(secret []byte, userID uuid.UUID) string {
	account := userID.String()[:8]
	query := url.Values{
		"secret":    {totpEncoding.EncodeToString(secret)},
		"issuer":    {"Liddr"},
		"algorithm": {"SHA1"},
		"digits":    {"6"},
		"period":    {"30"},
	}
	return "otpauth://totp/" + url.PathEscape("Liddr:"+account) + "?" + query.Encode()
}
