package auth

import (
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

func TestGoogleAccountLinking(t *testing.T) {
	pool := testdb.Pool(t)
	q := store.New(pool)
	now := time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)

	existing, err := q.UpsertUserByEmail(t.Context(), new("owner@example.com"))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}

	verified, err := resolveGoogleAccount(t.Context(), q, GoogleIdentity{Subject: "s1", Email: "owner@example.com", EmailVerified: true}, now)
	if err != nil || verified.id != existing.ID {
		t.Errorf("a verified email should reach its account: %+v, %v", verified, err)
	}
	unverified, err := resolveGoogleAccount(t.Context(), q, GoogleIdentity{Subject: "s2", Email: "owner@example.com", EmailVerified: false}, now)
	if err != nil || unverified.id == existing.ID {
		t.Errorf("an unverified email reached someone else's account: %+v, %v", unverified, err)
	}
	again, err := resolveGoogleAccount(t.Context(), q, GoogleIdentity{Subject: "s2"}, now)
	if err != nil || again.id != unverified.id {
		t.Errorf("returning user = %+v, %v, want %v", again, err, unverified.id)
	}
}
