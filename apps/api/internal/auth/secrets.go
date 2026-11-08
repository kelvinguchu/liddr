package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"math/big"
	"net/netip"
	"strings"

	"github.com/google/uuid"
)

const (
	tokenBytes  = 32
	otpCodeSpan = 1_000_000
)

// hasher derives keyed hashes. A sign-in code has only a million values, so a
// plain hash of one could be reversed instantly from a database leak.
type hasher struct {
	key []byte
}

func (h hasher) mac(domain string, parts ...[]byte) []byte {
	mac := hmac.New(sha256.New, h.key)
	mac.Write([]byte(domain))
	mac.Write([]byte{0})
	for _, part := range parts {
		mac.Write(part)
	}
	return mac.Sum(nil)
}

// code binds a sign-in code to its challenge, so equal codes hash differently.
func (h hasher) code(challengeID uuid.UUID, code string) []byte {
	return h.mac("otp-code", challengeID[:], []byte(code))
}

func (h hasher) ip(addr netip.Addr) []byte {
	return h.mac("rate-limit-ip", []byte(addr.String()))
}

func newOTPCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(otpCodeSpan))
	if err != nil {
		return "", fmt.Errorf("generate sign-in code: %w", err)
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func newToken() (token string, hash []byte) {
	raw := make([]byte, tokenBytes)
	// crypto/rand.Read never returns an error; it aborts the program instead.
	_, _ = rand.Read(raw)
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, hashToken(token)
}

// hashToken needs no key or salt because tokens carry 256 bits of randomness.
func hashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

// NormalizePhone converts a Kenyan mobile number to 2547XXXXXXXX or 2541XXXXXXXX,
// the format M-Pesa and the SMS provider expect.
func NormalizePhone(raw string) (string, error) {
	const maxInputLength = 24
	if len(raw) > maxInputLength {
		return "", ErrInvalidPhone
	}
	number, international := strings.CutPrefix(strings.TrimSpace(raw), "+")

	digits := make([]byte, 0, len(number))
	for i := range len(number) {
		switch c := number[i]; {
		case c >= '0' && c <= '9':
			digits = append(digits, c)
		case c == ' ' || c == '-':
		default:
			return "", ErrInvalidPhone
		}
	}

	subscriber := string(digits)
	switch {
	case len(subscriber) == 12 && strings.HasPrefix(subscriber, "254"):
		subscriber = subscriber[3:]
	case international:
		return "", ErrInvalidPhone
	case len(subscriber) == 10 && subscriber[0] == '0':
		subscriber = subscriber[1:]
	}
	if len(subscriber) != 9 || (subscriber[0] != '7' && subscriber[0] != '1') {
		return "", ErrInvalidPhone
	}
	return "254" + subscriber, nil
}
