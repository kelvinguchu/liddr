package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	minNameRunes = 2
	maxNameRunes = 60

	reasonAccountDeleted = "account_deleted"
)

// Errors returned when changing or closing an account.
var (
	ErrInvalidName       = errors.New("name is not valid")
	ErrNameLocked        = errors.New("name is locked after verification")
	ErrStaffAccount      = errors.New("staff accounts cannot be self-deleted")
	ErrAccountHasPenalty = errors.New("account has an active penalty")
	ErrTripInProgress    = errors.New("account has a trip in progress")
)

// NormalizeName tidies a person's name. Digits are refused so that a phone
// number cannot be passed to the other side of a trip as a name.
func NormalizeName(raw string) (string, error) {
	name := strings.Join(strings.Fields(raw), " ")
	if count := utf8.RuneCountInString(name); count < minNameRunes || count > maxNameRunes {
		return "", ErrInvalidName
	}
	for _, r := range name {
		if !unicode.IsLetter(r) && !unicode.IsMark(r) && !strings.ContainsRune(" '’.-", r) {
			return "", ErrInvalidName
		}
	}
	return name, nil
}

// DisplayName returns the account's name, or nil if none has been set.
func (s *Service) DisplayName(ctx context.Context, userID uuid.UUID) (*string, error) {
	name, err := s.queries.GetDisplayName(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("load display name: %w", err)
	}
	return name, nil
}

// SetDisplayName changes the account's name and returns the stored form.
func (s *Service) SetDisplayName(ctx context.Context, userID uuid.UUID, raw string) (string, error) {
	name, err := NormalizeName(raw)
	if err != nil {
		return "", err
	}
	updated, err := s.queries.SetDisplayName(ctx, store.SetDisplayNameParams{DisplayName: new(name), Now: s.now(), ID: userID})
	if err != nil {
		return "", fmt.Errorf("set display name: %w", err)
	}
	if updated == 0 {
		return "", ErrNameLocked
	}
	return name, nil
}

// DeleteAccount removes the person's details and ends every session. The row
// stays, emptied, because ride and payment records must be kept for years and
// point at it. A penalty blocks deletion, since the same phone number could
// otherwise sign up again with a clean record.
func (s *Service) DeleteAccount(ctx context.Context, p Principal, meta RequestMeta) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetAccountForDeletion(ctx, p.UserID)
		if err != nil {
			return fmt.Errorf("load account: %w", err)
		}
		if row.IsStaff {
			return ErrStaffAccount
		}
		if err := requireFreshSignIn(ctx, q, p, now); err != nil {
			return err
		}
		if row.AccountStatus != "active" || (row.BookingRestrictedUntil != nil && row.BookingRestrictedUntil.After(now)) {
			return ErrAccountHasPenalty
		}
		active, err := q.HasActiveTrip(ctx, p.UserID)
		if err != nil {
			return fmt.Errorf("check active trip: %w", err)
		}
		if active {
			return ErrTripInProgress
		}
		if err := eraseAccount(ctx, q, p.UserID, s); err != nil {
			return err
		}
		return audit(ctx, q, auditEntry{action: "account.deleted", userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now})
	})
}

func eraseAccount(ctx context.Context, q *store.Queries, id uuid.UUID, s *Service) error {
	now := s.now()
	steps := []struct {
		name string
		run  func() error
	}{
		{"anonymize user", func() error { return q.AnonymizeUser(ctx, store.AnonymizeUserParams{Now: new(now), ID: id}) }},
		{"delete identities", func() error { return q.DeleteAuthIdentities(ctx, id) }},
		{"revoke sessions", func() error {
			return q.RevokeUserSessions(ctx, store.RevokeUserSessionsParams{Now: new(now), Reason: new(reasonAccountDeleted), ID: id})
		}},
		{"revoke push tokens", func() error {
			return q.RevokeUserPushTokens(ctx, store.RevokeUserPushTokensParams{Now: new(now), ID: id})
		}},
		{"delete notifications", func() error { return q.DeleteUserNotifications(ctx, id) }},
		{"delete driver position", func() error { return q.DeleteDriverPosition(ctx, id) }},
		{"retire driver", func() error { return q.RetireDriver(ctx, store.RetireDriverParams{Now: now, ID: id}) }},
	}
	for _, step := range steps {
		if err := step.run(); err != nil {
			return fmt.Errorf("%s: %w", step.name, err)
		}
	}
	return nil
}
