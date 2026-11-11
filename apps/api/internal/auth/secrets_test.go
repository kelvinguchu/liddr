package auth

import (
	"errors"
	"regexp"
	"testing"
)

func TestNormalizePhone(t *testing.T) {
	const want = "254712345678"
	valid := []struct{ name, input, want string }{
		{"local", "0712345678", want},
		{"subscriber only", "712345678", want},
		{"international", "254712345678", want},
		{"international plus", "+254712345678", want},
		{"spaces", " 0712 345 678 ", want},
		{"hyphens", "+254-712-345-678", want},
		{"newer prefix", "0110123456", "254110123456"},
	}
	for _, tt := range valid {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NormalizePhone(tt.input)
			if err != nil {
				t.Fatalf("NormalizePhone(%q) = %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("NormalizePhone(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}

	invalid := map[string]string{
		"empty":                   "",
		"letters mixed in":        "call 0712345678",
		"landline":                "0201234567",
		"country code only":       "254",
		"zero subscriber":         "254012345678",
		"too short":               "07123456",
		"too long":                "07123456789",
		"foreign country":         "+14155550123",
		"plus on local form":      "+0712345678",
		"overlong input":          "0712345678 0712345678 0712345678",
		"non ascii digits":        "٠٧١٢٣٤٥٦٧٨",
		"parenthesised separator": "(0712)345678",
	}
	for name, input := range invalid {
		t.Run(name, func(t *testing.T) {
			if got, err := NormalizePhone(input); !errors.Is(err, ErrInvalidPhone) {
				t.Errorf("NormalizePhone(%q) = %q, %v, want ErrInvalidPhone", input, got, err)
			}
		})
	}
}

var normalizedPhone = regexp.MustCompile(`^254[17][0-9]{8}$`)

func FuzzNormalizePhone(f *testing.F) {
	for _, seed := range []string{"0712345678", "+254712345678", "", "٠٧", "254 7"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, input string) {
		got, err := NormalizePhone(input)
		if err != nil {
			return
		}
		if !normalizedPhone.MatchString(got) {
			t.Fatalf("NormalizePhone(%q) = %q, which the database would reject", input, got)
		}
		again, err := NormalizePhone(got)
		if err != nil || again != got {
			t.Fatalf("not idempotent: %q then %q, %v", got, again, err)
		}
	})
}

func TestOTPCodesAreSixDigits(t *testing.T) {
	pattern := regexp.MustCompile(`^[0-9]{6}$`)
	for range 1000 {
		code, err := newOTPCode()
		if err != nil {
			t.Fatalf("newOTPCode: %v", err)
		}
		if !pattern.MatchString(code) {
			t.Fatalf("code = %q", code)
		}
	}
}
