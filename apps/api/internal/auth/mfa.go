package auth

import (
	"context"
	"crypto/hmac"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	totpSetupTTL     = 10 * time.Minute
	stepUpTTL        = 5 * time.Minute
	totpMaxFailures  = 5
	totpLockDuration = 5 * time.Minute

	// freshSignInWindow is how recently a phone code must have been proven to
	// enrol for the first time. It stops a stolen, long-lived session from
	// attaching the thief's authenticator to a staff account.
	freshSignInWindow = 15 * time.Minute

	stepUpPayloadBytes = 16 + 16 + 8
)

// Errors returned by the two-factor flows.
var (
	ErrFreshSignInRequired = errors.New("enrolment needs a recent sign-in")
	ErrStepUpRequired      = errors.New("step-up is required")
	ErrTOTPNotEnrolled     = errors.New("no authenticator is enrolled")
	ErrTOTPNoEnrolment     = errors.New("no authenticator enrolment is in progress")
	ErrTOTPInvalid         = errors.New("incorrect authenticator code")
	ErrTOTPLocked          = errors.New("too many incorrect authenticator codes")
)

// TOTPSetup is what an authenticator app needs to be enrolled.
type TOTPSetup struct {
	Secret    string
	URI       string
	ExpiresAt time.Time
}

// StepUp is a short-lived proof of a recent authenticator code.
type StepUp struct {
	Token     string
	ExpiresIn time.Duration
}

func totpBinding(userID uuid.UUID) string {
	return "totp:" + userID.String()
}

// BeginTOTPSetup starts enrolment. A first enrolment needs a recent sign-in.
// Replacing a working authenticator needs a code from it, as a step-up token.
func (s *Service) BeginTOTPSetup(ctx context.Context, p Principal, stepUpToken string, meta RequestMeta) (TOTPSetup, error) {
	now := s.now()
	secret := newTOTPSecret()
	setup := TOTPSetup{
		Secret:    totpEncoding.EncodeToString(secret),
		URI:       totpURI(secret, p.UserID),
		ExpiresAt: now.Add(totpSetupTTL),
	}
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "totp:"+p.UserID.String()); err != nil {
			return fmt.Errorf("lock enrolment: %w", err)
		}
		if p.MFAEnrolled {
			if err := s.CheckStepUp(p, stepUpToken); err != nil {
				return err
			}
		} else if err := requireFreshSignIn(ctx, q, p, now); err != nil {
			return err
		}
		err := q.BeginTOTPEnrolment(ctx, store.BeginTOTPEnrolmentParams{
			UserID:    p.UserID,
			Sealed:    s.box.Seal(secret, totpBinding(p.UserID)),
			ExpiresAt: new(setup.ExpiresAt),
			Now:       now,
		})
		if err != nil {
			return fmt.Errorf("begin enrolment: %w", err)
		}
		return audit(ctx, q, auditEntry{action: "auth.totp_enrolment_started", userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now})
	})
	if err != nil {
		return TOTPSetup{}, err
	}
	return setup, nil
}

func requireFreshSignIn(ctx context.Context, q *store.Queries, p Principal, now time.Time) error {
	startedAt, err := q.GetFamilyStartedAt(ctx, p.FamilyID)
	if err != nil {
		return fmt.Errorf("load session age: %w", err)
	}
	if now.Sub(startedAt) > freshSignInWindow {
		return ErrFreshSignInRequired
	}
	return nil
}

// ConfirmTOTPSetup proves the authenticator holds the secret and activates it.
func (s *Service) ConfirmTOTPSetup(ctx context.Context, p Principal, code string, meta RequestMeta) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetTOTPForUpdate(ctx, p.UserID)
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Reject(ErrTOTPNoEnrolment)
		}
		if err != nil {
			return fmt.Errorf("load enrolment: %w", err)
		}
		if row.PendingSecretSealed == nil || !now.Before(*row.PendingExpiresAt) {
			return store.Reject(ErrTOTPNoEnrolment)
		}
		secret, err := s.box.Open(row.PendingSecretSealed, totpBinding(p.UserID))
		if err != nil {
			return fmt.Errorf("open enrolment secret: %w", err)
		}
		counter, ok := matchTOTP(secret, code, now)
		if !ok {
			return s.recordEnrolmentFailure(ctx, q, p.UserID, row.PendingAttempts, now)
		}
		// Storing the counter stops the code that confirmed enrolment from also
		// passing the first step-up.
		err = q.ConfirmTOTPEnrolment(ctx, store.ConfirmTOTPEnrolmentParams{Now: new(now), Counter: counter, UserID: p.UserID})
		if err != nil {
			return fmt.Errorf("confirm enrolment: %w", err)
		}
		return audit(ctx, q, auditEntry{action: "auth.totp_enrolled", userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now})
	})
}

func (s *Service) recordEnrolmentFailure(ctx context.Context, q *store.Queries, userID uuid.UUID, attempts int32, now time.Time) error {
	if attempts+1 >= totpMaxFailures {
		if err := q.DiscardPendingTOTP(ctx, store.DiscardPendingTOTPParams{Now: now, UserID: userID}); err != nil {
			return fmt.Errorf("discard enrolment: %w", err)
		}
		return store.Reject(ErrTOTPLocked)
	}
	if err := q.RecordPendingTOTPFailure(ctx, store.RecordPendingTOTPFailureParams{Now: now, UserID: userID}); err != nil {
		return fmt.Errorf("record enrolment failure: %w", err)
	}
	return store.Reject(ErrTOTPInvalid)
}

// VerifyStepUp spends an authenticator code. A code works once, and repeated
// failures lock the account's authenticator for a few minutes.
func (s *Service) VerifyStepUp(ctx context.Context, p Principal, code string, meta RequestMeta) (StepUp, error) {
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetTOTPForUpdate(ctx, p.UserID)
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Reject(ErrTOTPNotEnrolled)
		}
		if err != nil {
			return fmt.Errorf("load authenticator: %w", err)
		}
		if row.SecretSealed == nil {
			return store.Reject(ErrTOTPNotEnrolled)
		}
		if row.LockedUntil != nil && now.Before(*row.LockedUntil) {
			return store.Reject(ErrTOTPLocked)
		}
		secret, err := s.box.Open(row.SecretSealed, totpBinding(p.UserID))
		if err != nil {
			return fmt.Errorf("open authenticator secret: %w", err)
		}
		counter, ok := matchTOTP(secret, code, now)
		if !ok || counter <= row.LastCounter {
			return s.recordStepUpFailure(ctx, q, p, row.FailedAttempts, meta, now)
		}
		if err := q.RecordTOTPSuccess(ctx, store.RecordTOTPSuccessParams{Counter: counter, Now: now, UserID: p.UserID}); err != nil {
			return fmt.Errorf("record step-up: %w", err)
		}
		return audit(ctx, q, auditEntry{action: "auth.step_up_verified", userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now})
	})
	if err != nil {
		return StepUp{}, err
	}
	return StepUp{Token: s.stepUpToken(p, now.Add(stepUpTTL)), ExpiresIn: stepUpTTL}, nil
}

func (s *Service) recordStepUpFailure(ctx context.Context, q *store.Queries, p Principal, failures int32, meta RequestMeta, now time.Time) error {
	params := store.RecordTOTPFailureParams{FailedAttempts: failures + 1, Now: now, UserID: p.UserID}
	result := ErrTOTPInvalid
	if params.FailedAttempts >= totpMaxFailures {
		params.FailedAttempts = 0
		params.LockedUntil = new(now.Add(totpLockDuration))
		result = ErrTOTPLocked
		if err := audit(ctx, q, auditEntry{action: "auth.totp_locked", userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now}); err != nil {
			return err
		}
	}
	if err := q.RecordTOTPFailure(ctx, params); err != nil {
		return fmt.Errorf("record step-up failure: %w", err)
	}
	return store.Reject(result)
}

func (s *Service) stepUpToken(p Principal, expires time.Time) string {
	payload := make([]byte, 0, stepUpPayloadBytes)
	payload = append(payload, p.UserID[:]...)
	payload = append(payload, p.SessionID[:]...)
	payload = binary.BigEndian.AppendUint64(payload, uint64(expires.Unix())) //nolint:gosec // Times here are after 1970.
	return base64.RawURLEncoding.EncodeToString(append(payload, s.hasher.mac("step-up", payload)...))
}

// CheckStepUp reports whether token is a live proof for this exact session.
func (s *Service) CheckStepUp(p Principal, token string) error {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(raw) <= stepUpPayloadBytes {
		return ErrStepUpRequired
	}
	payload, mac := raw[:stepUpPayloadBytes], raw[stepUpPayloadBytes:]
	if !hmac.Equal(mac, s.hasher.mac("step-up", payload)) {
		return ErrStepUpRequired
	}
	if !hmac.Equal(payload[:16], p.UserID[:]) || !hmac.Equal(payload[16:32], p.SessionID[:]) {
		return ErrStepUpRequired
	}
	expires := time.Unix(int64(binary.BigEndian.Uint64(payload[32:])), 0) //nolint:gosec // Written by stepUpToken.
	if !s.now().Before(expires) {
		return ErrStepUpRequired
	}
	return nil
}
