// Package subscriptions owns weekly driver subscriptions and how they are paid.
package subscriptions

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Errors returned to callers.
var (
	ErrProfileMissing  = errors.New("driver profile does not exist")
	ErrNotVerified     = errors.New("driver is not verified")
	ErrAlreadyActive   = errors.New("subscription is already active")
	ErrPaymentPending  = errors.New("a payment is already in progress")
	ErrRateLimited     = errors.New("too many payment attempts")
	ErrPaymentRefused  = errors.New("m-pesa refused the payment request")
	ErrCallbackRefused = errors.New("callback is not authorized")
)

// Gateway is the part of M-Pesa that subscriptions depend on.
type Gateway interface {
	InitiateSTK(ctx context.Context, req payments.STKRequest) (payments.STKResponse, error)
	QuerySTK(ctx context.Context, checkoutRequestID string) (payments.QueryResult, error)
}

// Config holds the dependencies of a Service.
type Config struct {
	Pool            *pgxpool.Pool
	Gateway         Gateway
	Now             func() time.Time
	Logger          *slog.Logger
	CallbackBaseURL string
	CallbackToken   string
	Shortcode       string
}

// Service implements subscription payment.
type Service struct {
	pool      *pgxpool.Pool
	queries   *store.Queries
	gateway   Gateway
	now       func() time.Time
	logger    *slog.Logger
	baseURL   string
	token     string
	shortcode string
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{
		pool:      cfg.Pool,
		queries:   store.New(cfg.Pool),
		gateway:   cfg.Gateway,
		now:       cfg.Now,
		logger:    cfg.Logger,
		baseURL:   strings.TrimRight(cfg.CallbackBaseURL, "/"),
		token:     cfg.CallbackToken,
		shortcode: cfg.Shortcode,
	}
}

// VerifyCallbackToken compares in constant time.
func (s *Service) VerifyCallbackToken(token string) bool {
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) == 1
}

func (s *Service) callbackURL(path string) string {
	return s.baseURL + "/v1/webhooks/mpesa/" + s.token + path
}

// C2BURLs returns the validation and confirmation URLs to register with Daraja.
func (s *Service) C2BURLs() (validation, confirmation string) {
	return s.callbackURL("/c2b/validation"), s.callbackURL("/c2b/confirmation")
}

var nairobi = time.FixedZone("EAT", 3*60*60)

// dateOf returns the Nairobi calendar date of t, as midnight UTC.
func dateOf(t time.Time) time.Time {
	local := t.In(nairobi)
	return time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
}

// weekStart returns the Monday of the Nairobi week containing t. Using UTC here
// would put Sunday night's payments in the wrong week for three hours.
func weekStart(t time.Time) time.Time {
	date := dateOf(t)
	return date.AddDate(0, 0, -(int(date.Weekday())+6)%7)
}

func newReference() string {
	return "LDR" + rand.Text()[:8]
}

type weekSpec struct {
	driverID   uuid.UUID
	categoryID int64
	amountKES  int32
	start      time.Time
	at         time.Time
}

// ensureWeek returns the driver's locked subscription for a week, creating it
// if needed. An unpaid week follows the current price, so that a price change,
// such as applying test prices, reaches a week already opened at the old one.
func ensureWeek(ctx context.Context, q *store.Queries, spec weekSpec) (store.Subscription, error) {
	err := q.InsertSubscriptionIfAbsent(ctx, store.InsertSubscriptionIfAbsentParams{
		ID:                uuid.New(),
		DriverID:          spec.driverID,
		VehicleCategoryID: spec.categoryID,
		WeekStart:         spec.start,
		WeekEnd:           spec.start.AddDate(0, 0, 6),
		AmountKes:         spec.amountKES,
		Reference:         newReference(),
		CreatedAt:         spec.at,
	})
	if err != nil {
		return store.Subscription{}, fmt.Errorf("insert subscription: %w", err)
	}
	sub, err := q.GetSubscriptionForWeek(ctx, store.GetSubscriptionForWeekParams{DriverID: spec.driverID, WeekStart: spec.start})
	if err != nil {
		return store.Subscription{}, fmt.Errorf("load subscription: %w", err)
	}
	if sub.Status == "pending" && (sub.AmountKes != spec.amountKES || sub.VehicleCategoryID != spec.categoryID) {
		err := q.SyncPendingSubscription(ctx, store.SyncPendingSubscriptionParams{AmountKes: spec.amountKES, VehicleCategoryID: spec.categoryID, ID: sub.ID})
		if err != nil {
			return store.Subscription{}, fmt.Errorf("sync subscription: %w", err)
		}
		sub.AmountKes, sub.VehicleCategoryID = spec.amountKES, spec.categoryID
	}
	return sub, nil
}

func lockPayingDriver(ctx context.Context, q *store.Queries, driverID uuid.UUID) (store.GetDriverForPaymentRow, error) {
	driver, err := q.GetDriverForPayment(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.GetDriverForPaymentRow{}, ErrProfileMissing
	}
	if err != nil {
		return store.GetDriverForPaymentRow{}, fmt.Errorf("load driver: %w", err)
	}
	return driver, nil
}

// Summary is what a driver needs to know to pay this week.
type Summary struct {
	Status    string
	AmountKES int32
	WeekStart time.Time
	WeekEnd   time.Time
	Reference string
	Shortcode string
}

// Current returns this week's subscription, opening it if needed so that the
// driver has a reference for paying by paybill.
func (s *Service) Current(ctx context.Context, driverID uuid.UUID) (Summary, error) {
	var summary Summary
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		driver, err := lockPayingDriver(ctx, q, driverID)
		if err != nil {
			return err
		}
		now := s.now()
		sub, err := ensureWeek(ctx, q, weekSpec{driverID: driverID, categoryID: driver.VehicleCategoryID, amountKES: driver.WeeklySubscriptionKes, start: weekStart(now), at: now})
		if err != nil {
			return err
		}
		summary = Summary{Status: sub.Status, AmountKES: sub.AmountKes, WeekStart: sub.WeekStart, WeekEnd: sub.WeekEnd, Reference: sub.Reference, Shortcode: s.shortcode}
		return nil
	})
	return summary, err
}
