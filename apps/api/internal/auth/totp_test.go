package auth

import (
	"testing"
	"time"
)

// The expected values are the SHA1 vectors from RFC 6238, Appendix B, reduced
// from eight digits to six.
func TestTOTPMatchesRFC6238(t *testing.T) {
	secret := []byte("12345678901234567890")
	cases := []struct {
		name string
		unix int64
		want string
	}{
		{"59", 59, "287082"},
		{"1111111109", 1111111109, "081804"},
		{"1111111111", 1111111111, "050471"},
		{"1234567890", 1234567890, "005924"},
		{"2000000000", 2000000000, "279037"},
		{"20000000000", 20000000000, "353130"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := totpCode(secret, totpCounter(time.Unix(tc.unix, 0))); got != tc.want {
				t.Errorf("code = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestMatchTOTPAllowsOnePeriodOfDriftOnly(t *testing.T) {
	secret := []byte("12345678901234567890")
	now := time.Unix(1_700_000_000, 0)
	counter := totpCounter(now)
	cases := []struct {
		name   string
		offset int64
		want   bool
	}{
		{"current", 0, true},
		{"one behind", -1, true},
		{"one ahead", 1, true},
		{"two behind", -2, false},
		{"two ahead", 2, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := matchTOTP(secret, totpCode(secret, counter+tc.offset), now)
			if ok != tc.want {
				t.Fatalf("matched = %v, want %v", ok, tc.want)
			}
			if ok && got != counter+tc.offset {
				t.Errorf("counter = %d, want %d", got, counter+tc.offset)
			}
		})
	}
}
