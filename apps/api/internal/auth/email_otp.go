package auth

import (
	"context"
	"crypto/hmac"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// RequestEmailOTP sends a sign-in code. Like phone sign-in, it reveals nothing
// about whether an account exists. New accounts made this way are riders,
// because a driver needs a verified phone for M-Pesa.
func (s *Service) RequestEmailOTP(ctx context.Context, rawEmail string, meta RequestMeta) (Challenge, error) {
	if s.email == nil {
		return Challenge{}, ErrEmailUnavailable
	}
	address, err := NormalizeEmail(rawEmail)
	if err != nil {
		return Challenge{}, err
	}
	code, err := newOTPCode()
	if err != nil {
		return Challenge{}, err
	}
	now := s.now()
	challenge := Challenge{ID: uuid.New(), ExpiresAt: now.Add(otpTTL)}
	ipHash := s.hasher.ip(meta.IP)
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := enforceEmailLimits(ctx, q, address, ipHash, now); err != nil {
			return err
		}
		if err := q.CloseOpenEmailChallenges(ctx, store.CloseOpenEmailChallengesParams{Now: new(now), Email: address}); err != nil {
			return fmt.Errorf("close open challenges: %w", err)
		}
		err := q.InsertEmailChallenge(ctx, store.InsertEmailChallengeParams{
			ID: challenge.ID, Email: address, CodeHash: s.hasher.code(challenge.ID, code), IpHash: ipHash, ExpiresAt: challenge.ExpiresAt, CreatedAt: now,
		})
		if err != nil {
			return fmt.Errorf("insert challenge: %w", err)
		}
		return nil
	})
	if err != nil {
		return Challenge{}, err
	}
	if err := s.email.Send(ctx, address, emailOTPSubject, fmt.Sprintf(emailOTPTemplate, code)); err != nil {
		return Challenge{}, errors.Join(ErrDeliveryUnavailable, err, s.markEmailFailed(ctx, challenge.ID))
	}
	return challenge, nil
}

func (s *Service) markEmailFailed(ctx context.Context, id uuid.UUID) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), deliveryFailureTimeout)
	defer cancel()
	if err := s.queries.MarkEmailChallengeFailed(ctx, store.MarkEmailChallengeFailedParams{Now: new(s.now()), ID: id}); err != nil {
		return fmt.Errorf("mark delivery failed: %w", err)
	}
	return nil
}

func enforceEmailLimits(ctx context.Context, q *store.Queries, address string, ipHash []byte, now time.Time) error {
	if err := q.LockKey(ctx, fmt.Sprintf("otp:ip:%x", ipHash)); err != nil {
		return fmt.Errorf("lock ip limit: %w", err)
	}
	if err := q.LockKey(ctx, "otp:email:"+address); err != nil {
		return fmt.Errorf("lock email limit: %w", err)
	}
	count, err := q.CountEmailChallengesByIP(ctx, store.CountEmailChallengesByIPParams{IpHash: ipHash, Since: now.Add(-ipWindow)})
	if err != nil {
		return fmt.Errorf("count ip challenges: %w", err)
	}
	if count >= maxCodesPerIP {
		return &RateLimitError{RetryAfter: ipWindow}
	}
	recent, err := q.ListRecentEmailChallenges(ctx, store.ListRecentEmailChallengesParams{Email: address, Since: now.Add(-phoneWindow)})
	if err != nil {
		return fmt.Errorf("list email challenges: %w", err)
	}
	if len(recent) > 0 && now.Sub(recent[0].CreatedAt) < phoneCooldown {
		return &RateLimitError{RetryAfter: phoneCooldown - now.Sub(recent[0].CreatedAt)}
	}
	var sent []time.Time
	for _, row := range recent {
		if row.DeliveryFailedAt == nil {
			sent = append(sent, row.CreatedAt)
		}
	}
	if len(sent) >= maxCodesPerEmail {
		return &RateLimitError{RetryAfter: sent[len(sent)-1].Add(phoneWindow).Sub(now)}
	}
	return nil
}

// VerifyEmailOTP exchanges a code for a session.
func (s *Service) VerifyEmailOTP(ctx context.Context, challengeID uuid.UUID, code string, meta RequestMeta) (Tokens, error) {
	var tokens Tokens
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		challenge, err := q.GetEmailChallengeForUpdate(ctx, challengeID)
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Reject(ErrCodeExpired)
		}
		if err != nil {
			return fmt.Errorf("load challenge: %w", err)
		}
		switch {
		case challenge.Attempts >= maxOTPAttempts:
			return store.Reject(ErrTooManyAttempts)
		case challenge.ClosedAt != nil || !now.Before(challenge.ExpiresAt):
			return store.Reject(ErrCodeExpired)
		}
		if !hmac.Equal(challenge.CodeHash, s.hasher.code(challenge.ID, code)) {
			err := q.RecordEmailChallengeFailure(ctx, store.RecordEmailChallengeFailureParams{MaxAttempts: maxOTPAttempts, Now: new(now), ID: challenge.ID})
			if err != nil {
				return fmt.Errorf("record failed attempt: %w", err)
			}
			if challenge.Attempts+1 >= maxOTPAttempts {
				return store.Reject(ErrTooManyAttempts)
			}
			return store.Reject(ErrInvalidCode)
		}
		if err := q.CloseEmailChallenge(ctx, store.CloseEmailChallengeParams{Now: new(now), ID: challenge.ID}); err != nil {
			return fmt.Errorf("close challenge: %w", err)
		}
		user, err := q.UpsertUserByEmail(ctx, new(challenge.Email))
		if err != nil {
			return fmt.Errorf("upsert user: %w", err)
		}
		tokens, err = s.finishSignIn(ctx, q, account{id: user.ID, status: user.AccountStatus, created: user.Created}, meta, now)
		return err
	})
	if err != nil {
		return Tokens{}, err
	}
	return tokens, nil
}
