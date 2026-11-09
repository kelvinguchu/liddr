// Package auth owns phone sign-in, sessions and account access checks.
package auth

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/sealing"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Role is a permission set held by an account.
type Role string

// Roles an account can hold.
const (
	RoleRider  Role = "rider"
	RoleDriver Role = "driver"
	RoleOps    Role = "ops"
	RoleAdmin  Role = "admin"

	// RoleStaff is only a sign-in intent. It is never granted, and it succeeds
	// only for an account that already holds ops or admin.
	RoleStaff Role = "staff"
)

// Errors returned to callers. RateLimitError is also returned.
var (
	ErrInvalidPhone        = errors.New("invalid phone number")
	ErrInvalidRole         = errors.New("role cannot be requested at sign-in")
	ErrInvalidCode         = errors.New("incorrect sign-in code")
	ErrCodeExpired         = errors.New("sign-in code is no longer valid")
	ErrTooManyAttempts     = errors.New("too many incorrect sign-in codes")
	ErrDeliveryUnavailable = errors.New("sign-in code could not be sent")
	ErrInvalidToken        = errors.New("token is not valid")
	ErrAccountSuspended    = errors.New("account is suspended")
	ErrAccountBanned       = errors.New("account is banned")
	ErrAccountDeactivated  = errors.New("account is deactivated")
	ErrNotStaff            = errors.New("account has no staff access")
)

// RateLimitError reports that a request must wait before being retried.
type RateLimitError struct {
	RetryAfter time.Duration
}

func (e *RateLimitError) Error() string {
	return "too many sign-in code requests"
}

// SMSSender delivers a text message, returning nil only once it was accepted.
type SMSSender interface {
	Send(ctx context.Context, phone, message string) error
}

// Config holds the dependencies of a Service.
type Config struct {
	Pool    *pgxpool.Pool
	SMS     SMSSender
	HMACKey []byte
	Box     *sealing.Box
	Now     func() time.Time
}

// Service implements sign-in and session management.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	sms     SMSSender
	hasher  hasher
	box     *sealing.Box
	now     func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{
		pool:    cfg.Pool,
		queries: store.New(cfg.Pool),
		sms:     cfg.SMS,
		hasher:  hasher{key: cfg.HMACKey},
		box:     cfg.Box,
		now:     cfg.Now,
	}
}

// RequestMeta describes the request an action came from, for limits and audit.
type RequestMeta struct {
	IP        netip.Addr
	RequestID string
}

// statusError returns the error for a status that cannot sign in. Anything not
// known to be allowed is denied.
func statusError(status string) error {
	switch status {
	case "active", "restricted":
		return nil
	case "banned":
		return ErrAccountBanned
	case "deactivated":
		return ErrAccountDeactivated
	default:
		return ErrAccountSuspended
	}
}

type auditEntry struct {
	action string
	userID *uuid.UUID
	family *uuid.UUID
	meta   RequestMeta
	at     time.Time
}

func audit(ctx context.Context, q *store.Queries, entry auditEntry) error {
	err := q.InsertAuditEvent(ctx, store.InsertAuditEventParams{
		Action:    entry.action,
		UserID:    entry.userID,
		FamilyID:  entry.family,
		RequestID: entry.meta.RequestID,
		Ip:        entry.meta.IP,
		CreatedAt: entry.at,
	})
	if err != nil {
		return fmt.Errorf("record audit event %s: %w", entry.action, err)
	}
	return nil
}
