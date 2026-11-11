package auth

import (
	"context"
	"errors"
	"fmt"
	"net/mail"
	"net/netip"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	maxEmailLength   = 254
	emailOTPSubject  = "Your Liddr sign-in code"
	emailOTPTemplate = "Your Liddr sign-in code is %s.\n\nIt expires in 5 minutes. Do not share it with anyone."
	providerGoogle   = "google"
	maxCodesPerEmail = 3
)

// ErrInvalidEmail and ErrEmailUnavailable describe email sign-in problems.
var (
	ErrInvalidEmail     = errors.New("invalid email address")
	ErrEmailUnavailable = errors.New("email sign-in is unavailable")
)

// EmailSender delivers a message, returning nil only once it was accepted.
type EmailSender interface {
	Send(ctx context.Context, to, subject, text string) error
}

// NormalizeEmail returns a lowercase bare address.
func NormalizeEmail(raw string) (string, error) {
	trimmed := strings.ToLower(strings.TrimSpace(raw))
	if trimmed == "" || len(trimmed) > maxEmailLength {
		return "", ErrInvalidEmail
	}
	parsed, err := mail.ParseAddress(trimmed)
	if err != nil || parsed.Address != trimmed {
		return "", ErrInvalidEmail
	}
	return trimmed, nil
}

// SignInWithGoogle exchanges a Google ID token for a session. Only a verified
// Google email can join an existing email account; otherwise a person could
// claim someone else's address and walk into their account.
func (s *Service) SignInWithGoogle(ctx context.Context, idToken string, meta RequestMeta) (Tokens, error) {
	if s.google == nil {
		return Tokens{}, ErrGoogleUnavailable
	}
	identity, err := s.google.Verify(ctx, idToken)
	if err != nil {
		return Tokens{}, err
	}
	var tokens Tokens
	now := s.now()
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "identity:google:"+identity.Subject); err != nil {
			return fmt.Errorf("lock identity: %w", err)
		}
		acct, err := resolveGoogleAccount(ctx, q, identity, now)
		if err != nil {
			return err
		}
		tokens, err = s.finishSignIn(ctx, q, acct, meta, now)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}

func resolveGoogleAccount(ctx context.Context, q *store.Queries, identity GoogleIdentity, now time.Time) (account, error) {
	existing, err := q.GetIdentityUser(ctx, store.GetIdentityUserParams{Provider: providerGoogle, Subject: identity.Subject})
	if err == nil {
		if err := q.TouchIdentity(ctx, store.TouchIdentityParams{Now: now, Provider: providerGoogle, Subject: identity.Subject}); err != nil {
			return account{}, fmt.Errorf("touch identity: %w", err)
		}
		return account{id: existing.UserID, status: existing.AccountStatus}, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return account{}, fmt.Errorf("load identity: %w", err)
	}
	var acct account
	if identity.EmailVerified && identity.Email != "" {
		user, err := q.UpsertUserByEmail(ctx, new(identity.Email))
		if err != nil {
			return account{}, fmt.Errorf("upsert user: %w", err)
		}
		acct = account{id: user.ID, status: user.AccountStatus, created: user.Created}
	} else {
		user, err := q.CreateUserWithoutContact(ctx)
		if err != nil {
			return account{}, fmt.Errorf("create user: %w", err)
		}
		acct = account{id: user.ID, status: user.AccountStatus, created: true}
	}
	err = q.InsertIdentity(ctx, store.InsertIdentityParams{Provider: providerGoogle, Subject: identity.Subject, UserID: acct.id, Now: now})
	if err != nil {
		return account{}, fmt.Errorf("insert identity: %w", err)
	}
	return acct, nil
}

// finishSignIn applies account checks shared by the rider sign-in methods.
func (s *Service) finishSignIn(ctx context.Context, q *store.Queries, acct account, meta RequestMeta, now time.Time) (Tokens, error) {
	entry := auditEntry{userID: new(acct.id), meta: meta, at: now}
	if err := statusError(acct.status); err != nil {
		entry.action = "auth.sign_in_blocked"
		if auditErr := audit(ctx, q, entry); auditErr != nil {
			return Tokens{}, auditErr
		}
		return Tokens{}, store.Reject(err)
	}
	if err := q.GrantInitialRole(ctx, store.GrantInitialRoleParams{UserID: acct.id, Role: string(RoleRider)}); err != nil {
		return Tokens{}, fmt.Errorf("grant role: %w", err)
	}
	tokens, err := s.issue(ctx, q, acct.id, uuid.New(), now)
	if err != nil {
		return Tokens{}, err
	}
	entry.action = "auth.signed_in"
	if acct.created {
		entry.action = "auth.signed_up"
	}
	return tokens, audit(ctx, q, entry)
}

// EmailEnabled reports whether email sign-in is configured.
func (s *Service) EmailEnabled() bool { return s.email != nil }

// GoogleEnabled reports whether Google sign-in is configured.
func (s *Service) GoogleEnabled() bool { return s.google != nil }

// GrantRole gives a phone number a role, creating the account if needed. It is
// an operator command, so that no public route can ever create staff.
func (s *Service) GrantRole(ctx context.Context, rawPhone string, role Role) error {
	if role != RoleOps && role != RoleAdmin {
		return ErrInvalidRole
	}
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return err
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		user, err := q.UpsertUserByPhone(ctx, new(phone))
		if err != nil {
			return fmt.Errorf("upsert user: %w", err)
		}
		if err := q.GrantRole(ctx, store.GrantRoleParams{UserID: user.ID, Role: string(role)}); err != nil {
			return fmt.Errorf("grant role: %w", err)
		}
		return audit(ctx, q, auditEntry{action: "auth.role_granted." + string(role), userID: new(user.ID), meta: RequestMeta{IP: netip.IPv4Unspecified(), RequestID: "operator-cli"}, at: now})
	})
}

type account struct {
	id      uuid.UUID
	status  string
	created bool
}

// resolveAccount finds or creates the account a proven code signs in to. A
// staff sign-in never creates one, because staff roles are granted by operators.
func resolveAccount(ctx context.Context, q *store.Queries, phone, requestedRole string) (account, error) {
	if requestedRole == string(RoleStaff) {
		staff, err := q.GetStaffUserByPhone(ctx, new(phone))
		if errors.Is(err, pgx.ErrNoRows) {
			return account{}, store.Reject(ErrNotStaff)
		}
		if err != nil {
			return account{}, fmt.Errorf("load staff account: %w", err)
		}
		return account{id: staff.ID, status: staff.AccountStatus}, nil
	}
	user, err := q.UpsertUserByPhone(ctx, new(phone))
	if err != nil {
		return account{}, fmt.Errorf("upsert user: %w", err)
	}
	return account{id: user.ID, status: user.AccountStatus, created: user.Created}, nil
}
