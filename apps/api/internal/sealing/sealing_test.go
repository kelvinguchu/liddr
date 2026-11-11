package sealing

import (
	"bytes"
	"errors"
	"testing"
)

func TestSealedValueOnlyOpensWhereItBelongs(t *testing.T) {
	box, err := New(bytes.Repeat([]byte{7}, KeyBytes))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	other, err := New(bytes.Repeat([]byte{8}, KeyBytes))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	sealed := box.Seal([]byte("secret"), "totp:a")
	if bytes.Contains(sealed, []byte("secret")) {
		t.Fatal("sealed value contains the plaintext")
	}
	got, err := box.Open(sealed, "totp:a")
	if err != nil || string(got) != "secret" {
		t.Fatalf("Open = %q, %v", got, err)
	}

	tampered := bytes.Clone(sealed)
	tampered[len(tampered)-1] ^= 1
	cases := []struct {
		name    string
		box     *Box
		value   []byte
		binding string
	}{
		{"another row", box, sealed, "totp:b"},
		{"another key", other, sealed, "totp:a"},
		{"tampered", box, tampered, "totp:a"},
		{"empty", box, nil, "totp:a"},
		{"unknown version", box, append([]byte{9}, sealed[1:]...), "totp:a"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := tc.box.Open(tc.value, tc.binding); !errors.Is(err, ErrCorrupt) {
				t.Errorf("Open = %v, want ErrCorrupt", err)
			}
		})
	}
}

func TestRepeatedSealsDiffer(t *testing.T) {
	box, err := New(bytes.Repeat([]byte{7}, KeyBytes))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if bytes.Equal(box.Seal([]byte("x"), "b"), box.Seal([]byte("x"), "b")) {
		t.Error("two seals of one value were identical, so the nonce is not random")
	}
}

func TestNewRejectsShortKey(t *testing.T) {
	if _, err := New([]byte("short")); err == nil {
		t.Error("New accepted a short key")
	}
}
