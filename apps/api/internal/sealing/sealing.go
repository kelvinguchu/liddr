// Package sealing encrypts critical columns before they reach the database.
package sealing

import (
	"crypto/aes"
	"crypto/cipher"
	"errors"
	"fmt"
)

// version leads every sealed value, so that a later key can be added without
// rewriting existing rows.
const version byte = 1

// KeyBytes is the required key length.
const KeyBytes = 32

// ErrCorrupt reports a value that was altered, moved or sealed under another key.
var ErrCorrupt = errors.New("sealed value cannot be opened")

// Box seals values with AES-256-GCM.
type Box struct {
	aead cipher.AEAD
}

// New returns a Box using key, which must be KeyBytes long.
func New(key []byte) (*Box, error) {
	if len(key) != KeyBytes {
		return nil, fmt.Errorf("sealing key must be %d bytes", KeyBytes)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("create cipher: %w", err)
	}
	aead, err := cipher.NewGCMWithRandomNonce(block)
	if err != nil {
		return nil, fmt.Errorf("create aead: %w", err)
	}
	return &Box{aead: aead}, nil
}

// Seal encrypts plaintext. binding names the row and column the value belongs
// to, so a value copied to another account cannot be opened there.
func (b *Box) Seal(plaintext []byte, binding string) []byte {
	// The nil nonce is deliberate: this AEAD generates a random one for each call.
	return b.aead.Seal([]byte{version}, nil, plaintext, []byte(binding)) //nolint:gosec // See above.
}

// Open decrypts a value produced by Seal with the same binding.
func (b *Box) Open(sealed []byte, binding string) ([]byte, error) {
	if len(sealed) < 1 || sealed[0] != version {
		return nil, ErrCorrupt
	}
	plaintext, err := b.aead.Open(nil, nil, sealed[1:], []byte(binding))
	if err != nil {
		return nil, ErrCorrupt
	}
	return plaintext, nil
}
