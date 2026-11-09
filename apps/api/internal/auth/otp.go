package auth

import (
	"context"
	"crypto/hmac"
	"errors"
	"fmt"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	otpTTL         = 5 * time.Minute
	maxOTPAttempts = 5

	phoneCooldown    = 30 * time.Second
	phoneWindow      = time.Hour
	maxCodesPerPhone = 3
	ipWindow         = 15 * time.Minute
	maxCodesPerIP    = 60

	deliveryFailureTimeout = 5 * time.Second
	otpMessageFormat       = "Liddr Security Code\n\nYour verification code is: %s\n\n" +
		"This code expires in 5 minutes. Do not share this code with anyone.\n\n@liddr.app #%s"
)

// OTPRequest asks for a sign-in code.
type OTPRequest struct {
	Phone string
	Role  Role
	Meta  RequestMeta
}

// Challenge identifies a sign-in code that was sent.
type Challenge struct {
	ID        uuid.UUID
	ExpiresAt time.Time
}

// RequestOTP sends a sign-in code. It reveals nothing about whether an account
// exists or is blocked, which is only disclosed after the code is proven.
func (s *Service) RequestOTP(ctx context.Context, req OTPRequest) (Challenge, error) {
	phone, err := NormalizePhone(req.Phone)
	if err != nil {
		return Challenge{}, err
	}
	if req.Role != RoleRider && req.Role != RoleDriver && req.Role != RoleStaff {
		return Challenge{}, ErrInvalidRole
	}
	code, err := newOTPCode()
	if err != nil {
		return Challenge{}, err
	}

	now := s.now()
	challenge := Challenge{ID: uuid.New(), ExpiresAt: now.Add(otpTTL)}
	ipHash := s.hasher.ip(req.Meta.IP)

	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := enforceLimits(ctx, q, phone, ipHash, now); err != nil {
			return err
		}
		// Only the newest code for a number can ever be used.
		if err := q.CloseOpenChallenges(ctx, store.CloseOpenChallengesParams{Now: new(now), Phone: phone}); err != nil {
			return fmt.Errorf("close open challenges: %w", err)
		}
		err := q.InsertChallenge(ctx, store.InsertChallengeParams{
			ID:            challenge.ID,
			Phone:         phone,
			RequestedRole: string(req.Role),
			CodeHash:      s.hasher.code(challenge.ID, code),
			IpHash:        ipHash,
			ExpiresAt:     challenge.ExpiresAt,
			CreatedAt:     now,
		})
		if err != nil {
			return fmt.Errorf("insert challenge: %w", err)
		}
		return nil
	})
	if err != nil {
		return Challenge{}, err
	}

	// Sent after commit: a slow provider must never hold a transaction open.
	if err := s.sms.Send(ctx, phone, fmt.Sprintf(otpMessageFormat, code, code)); err != nil {
		return Challenge{}, errors.Join(ErrDeliveryUnavailable, err, s.markDeliveryFailed(ctx, challenge.ID))
	}
	return challenge, nil
}

// markDeliveryFailed keeps the row, so the cooldown and IP limit still apply.
// It outlives the request because the client may be why delivery failed.
func (s *Service) markDeliveryFailed(ctx context.Context, id uuid.UUID) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), deliveryFailureTimeout)
	defer cancel()
	err := s.queries.MarkChallengeDeliveryFailed(ctx, store.MarkChallengeDeliveryFailedParams{Now: new(s.now()), ID: id})
	if err != nil {
		return fmt.Errorf("mark delivery failed: %w", err)
	}
	return nil
}

// enforceLimits holds advisory locks until commit, so concurrent requests are
// counted one after another. IP is always locked before phone to avoid deadlock.
func enforceLimits(ctx context.Context, q *store.Queries, phone string, ipHash []byte, now time.Time) error {
	if err := q.LockKey(ctx, fmt.Sprintf("otp:ip:%x", ipHash)); err != nil {
		return fmt.Errorf("lock ip limit: %w", err)
	}
	if err := q.LockKey(ctx, "otp:phone:"+phone); err != nil {
		return fmt.Errorf("lock phone limit: %w", err)
	}

	count, err := q.CountChallengesByIP(ctx, store.CountChallengesByIPParams{IpHash: ipHash, Since: now.Add(-ipWindow)})
	if err != nil {
		return fmt.Errorf("count ip challenges: %w", err)
	}
	if count >= maxCodesPerIP {
		return &RateLimitError{RetryAfter: ipWindow}
	}

	recent, err := q.ListRecentChallenges(ctx, store.ListRecentChallengesParams{Phone: phone, Since: now.Add(-phoneWindow)})
	if err != nil {
		return fmt.Errorf("list phone challenges: %w", err)
	}
	if len(recent) > 0 && now.Sub(recent[0].CreatedAt) < phoneCooldown {
		return &RateLimitError{RetryAfter: phoneCooldown - now.Sub(recent[0].CreatedAt)}
	}

	// Codes that never left do not use up the number's hourly allowance, so a
	// provider outage does not lock people out once it recovers.
	var sent []time.Time
	for _, row := range recent {
		if row.DeliveryFailedAt == nil {
			sent = append(sent, row.CreatedAt)
		}
	}
	if len(sent) >= maxCodesPerPhone {
		return &RateLimitError{RetryAfter: sent[len(sent)-1].Add(phoneWindow).Sub(now)}
	}
	return nil
}

// RetryAfterSeconds rounds up so a client waiting this long will not be refused.
func (e *RateLimitError) RetryAfterSeconds() int32 {
	return int32(min(math.Ceil(e.RetryAfter.Seconds()), math.MaxInt32))
}

// VerifyOTP exchanges a sign-in code for a session, creating the account on
// first use. Proving the code is the only way an account or role is created.
func (s *Service) VerifyOTP(ctx context.Context, challengeID uuid.UUID, code string, meta RequestMeta) (Tokens, error) {
	var tokens Tokens
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		challenge, err := q.GetChallengeForUpdate(ctx, challengeID)
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
			return recordWrongCode(ctx, q, challenge.ID, challenge.Attempts, now)
		}

		if err := q.CloseChallenge(ctx, store.CloseChallengeParams{Now: new(now), ID: challenge.ID}); err != nil {
			return fmt.Errorf("close challenge: %w", err)
		}
		user, err := resolveAccount(ctx, q, challenge.Phone, challenge.RequestedRole)
		if err != nil {
			return err
		}
		entry := auditEntry{userID: new(user.id), meta: meta, at: now}
		if err := statusError(user.status); err != nil {
			entry.action = "auth.sign_in_blocked"
			if auditErr := audit(ctx, q, entry); auditErr != nil {
				return auditErr
			}
			return store.Reject(err)
		}

		if challenge.RequestedRole != string(RoleStaff) {
			err = q.GrantInitialRole(ctx, store.GrantInitialRoleParams{UserID: user.id, Role: challenge.RequestedRole})
			if err != nil {
				return fmt.Errorf("grant role: %w", err)
			}
		}
		tokens, err = s.issue(ctx, q, user.id, uuid.New(), now)
		if err != nil {
			return err
		}
		entry.action = "auth.signed_in"
		if user.created {
			entry.action = "auth.signed_up"
		}
		return audit(ctx, q, entry)
	})
	if err != nil {
		return Tokens{}, err
	}
	return tokens, nil
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
		staff, err := q.GetStaffUserByPhone(ctx, phone)
		if errors.Is(err, pgx.ErrNoRows) {
			return account{}, store.Reject(ErrNotStaff)
		}
		if err != nil {
			return account{}, fmt.Errorf("load staff account: %w", err)
		}
		return account{id: staff.ID, status: staff.AccountStatus}, nil
	}
	user, err := q.UpsertUserByPhone(ctx, phone)
	if err != nil {
		return account{}, fmt.Errorf("upsert user: %w", err)
	}
	return account{id: user.ID, status: user.AccountStatus, created: user.Created}, nil
}

func recordWrongCode(ctx context.Context, q *store.Queries, id uuid.UUID, attempts int32, now time.Time) error {
	err := q.RecordChallengeFailure(ctx, store.RecordChallengeFailureParams{MaxAttempts: maxOTPAttempts, Now: new(now), ID: id})
	if err != nil {
		return fmt.Errorf("record failed attempt: %w", err)
	}
	if attempts+1 >= maxOTPAttempts {
		return store.Reject(ErrTooManyAttempts)
	}
	return store.Reject(ErrInvalidCode)
}
