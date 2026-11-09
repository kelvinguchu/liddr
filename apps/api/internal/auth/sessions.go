package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	accessTokenTTL  = 15 * time.Minute
	refreshTokenTTL = 30 * 24 * time.Hour

	// refreshRetryGrace lets a client resend a refresh whose response was lost
	// on a poor connection without being treated as a stolen token.
	refreshRetryGrace = 30 * time.Second
)

// Tokens is a newly issued session.
type Tokens struct {
	AccessToken  string
	RefreshToken string
	AccessTTL    time.Duration
	RefreshTTL   time.Duration
	UserID       uuid.UUID
	Roles        []Role
}

// Principal is the account behind a valid access token.
type Principal struct {
	UserID    uuid.UUID
	SessionID uuid.UUID
	FamilyID  uuid.UUID
	Phone     string
	Roles     []Role

	// MFAEnrolled reports whether the account has a confirmed authenticator.
	MFAEnrolled bool
}

func toRoles(values []string) []Role {
	roles := make([]Role, len(values))
	for i, value := range values {
		roles[i] = Role(value)
	}
	return roles
}

func (s *Service) issue(ctx context.Context, q *store.Queries, userID, familyID uuid.UUID, now time.Time) (Tokens, error) {
	tokens, _, err := s.insertSession(ctx, q, userID, familyID, now)
	return tokens, err
}

func (s *Service) insertSession(ctx context.Context, q *store.Queries, userID, familyID uuid.UUID, now time.Time) (Tokens, uuid.UUID, error) {
	id := uuid.New()
	accessToken, accessHash := newToken()
	refreshToken, refreshHash := newToken()
	err := q.InsertSession(ctx, store.InsertSessionParams{
		ID:               id,
		FamilyID:         familyID,
		UserID:           userID,
		AccessTokenHash:  accessHash,
		RefreshTokenHash: refreshHash,
		AccessExpiresAt:  now.Add(accessTokenTTL),
		RefreshExpiresAt: now.Add(refreshTokenTTL),
		CreatedAt:        now,
	})
	if err != nil {
		return Tokens{}, uuid.Nil, fmt.Errorf("insert session: %w", err)
	}
	roles, err := q.ListActiveRoles(ctx, userID)
	if err != nil {
		return Tokens{}, uuid.Nil, fmt.Errorf("list roles: %w", err)
	}
	return Tokens{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		AccessTTL:    accessTokenTTL,
		RefreshTTL:   refreshTokenTTL,
		UserID:       userID,
		Roles:        toRoles(roles),
	}, id, nil
}

// Authenticate resolves an access token with one read and takes no lock, so
// concurrent requests on a session never wait for each other.
func (s *Service) Authenticate(ctx context.Context, accessToken string) (Principal, error) {
	row, err := s.queries.AuthenticateAccessToken(ctx, store.AuthenticateAccessTokenParams{
		Hash: hashToken(accessToken),
		Now:  s.now(),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return Principal{}, ErrInvalidToken
	}
	if err != nil {
		return Principal{}, fmt.Errorf("authenticate access token: %w", err)
	}
	if err := statusError(row.AccountStatus); err != nil {
		return Principal{}, err
	}
	return Principal{
		UserID:    row.UserID,
		SessionID: row.SessionID,
		FamilyID:  row.FamilyID,
		Phone:     row.Phone,
		Roles:     toRoles(row.Roles),

		MFAEnrolled: row.MfaEnrolled,
	}, nil
}

// lockFamily finds the session for a refresh token and serializes all work on
// its family, so a revocation cannot miss a generation being created alongside.
func lockFamily(ctx context.Context, q *store.Queries, hash []byte) (store.GetSessionByRefreshHashRow, error) {
	family, err := q.GetFamilyByRefreshHash(ctx, hash)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.GetSessionByRefreshHashRow{}, store.Reject(ErrInvalidToken)
	}
	if err != nil {
		return store.GetSessionByRefreshHashRow{}, fmt.Errorf("find session family: %w", err)
	}
	if err := q.LockKey(ctx, "session:family:"+family.String()); err != nil {
		return store.GetSessionByRefreshHashRow{}, fmt.Errorf("lock session family: %w", err)
	}
	session, err := q.GetSessionByRefreshHash(ctx, hash)
	if err != nil {
		return store.GetSessionByRefreshHashRow{}, fmt.Errorf("load session: %w", err)
	}
	return session, nil
}

// Refresh spends a refresh token and issues new tokens in the same family.
func (s *Service) Refresh(ctx context.Context, refreshToken string, meta RequestMeta) (Tokens, error) {
	var tokens Tokens
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		session, err := lockFamily(ctx, q, hashToken(refreshToken))
		if err != nil {
			return err
		}
		if session.RevokedAt != nil {
			if err := s.checkRetry(ctx, q, session, meta, now); err != nil {
				return err
			}
		} else if !now.Before(session.RefreshExpiresAt) {
			return store.Reject(ErrInvalidToken)
		}

		status, err := q.GetUserAccountStatus(ctx, session.UserID)
		if err != nil {
			return fmt.Errorf("load account status: %w", err)
		}
		if err := statusError(status); err != nil {
			if err := revokeFamily(ctx, q, session, "account_blocked", meta, now); err != nil {
				return err
			}
			return store.Reject(err)
		}

		var newID uuid.UUID
		tokens, newID, err = s.insertSession(ctx, q, session.UserID, session.FamilyID, now)
		if err != nil {
			return err
		}
		if session.RevokedAt != nil {
			// Keep the original revocation time so retries cannot extend the grace.
			return wrapReplace(q.SetSessionReplacement(ctx, store.SetSessionReplacementParams{ReplacedByID: new(newID), ID: session.ID}))
		}
		return wrapReplace(q.MarkSessionRotated(ctx, store.MarkSessionRotatedParams{Now: new(now), ReplacedByID: new(newID), ID: session.ID}))
	})
	if err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}

func wrapReplace(err error) error {
	if err != nil {
		return fmt.Errorf("record replacement session: %w", err)
	}
	return nil
}

// checkRetry returns nil only for a client resending a refresh it just made,
// and supersedes the tokens that client never received. Any other use of a
// spent token means it was copied, so the whole family is revoked.
func (s *Service) checkRetry(ctx context.Context, q *store.Queries, session store.GetSessionByRefreshHashRow, meta RequestMeta, now time.Time) error {
	if session.RevokedReason == nil || *session.RevokedReason != "rotated" {
		return store.Reject(ErrInvalidToken)
	}
	if now.Sub(*session.RevokedAt) <= refreshRetryGrace && session.ReplacedByID != nil {
		replacementRevokedAt, err := q.GetSessionRevokedAt(ctx, *session.ReplacedByID)
		if err != nil {
			return fmt.Errorf("load replacement session: %w", err)
		}
		if replacementRevokedAt == nil {
			if err := q.SupersedeSession(ctx, store.SupersedeSessionParams{Now: new(now), ID: *session.ReplacedByID}); err != nil {
				return fmt.Errorf("supersede session: %w", err)
			}
			return nil
		}
	}
	if err := revokeFamily(ctx, q, session, "reuse_detected", meta, now); err != nil {
		return err
	}
	return store.Reject(ErrInvalidToken)
}

func revokeFamily(ctx context.Context, q *store.Queries, session store.GetSessionByRefreshHashRow, reason string, meta RequestMeta, now time.Time) error {
	err := q.RevokeFamily(ctx, store.RevokeFamilyParams{Now: new(now), Reason: new(reason), FamilyID: session.FamilyID})
	if err != nil {
		return fmt.Errorf("revoke session family: %w", err)
	}
	// A device that signed out must stop receiving this account's pushes.
	if err := q.RevokeFamilyPushTokens(ctx, store.RevokeFamilyPushTokensParams{Now: new(now), FamilyID: session.FamilyID}); err != nil {
		return fmt.Errorf("revoke push tokens: %w", err)
	}
	return audit(ctx, q, auditEntry{
		action: "auth.session_revoked." + reason,
		userID: new(session.UserID),
		family: new(session.FamilyID),
		meta:   meta,
		at:     now,
	})
}

// Logout ends the device's whole session family. An unknown or already ended
// token is success, because the caller's goal has been met either way.
func (s *Service) Logout(ctx context.Context, refreshToken string, meta RequestMeta) error {
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		session, err := lockFamily(ctx, q, hashToken(refreshToken))
		if err != nil {
			return err
		}
		return revokeFamily(ctx, q, session, "logout", meta, now)
	})
	if errors.Is(err, ErrInvalidToken) {
		return nil
	}
	return err
}
