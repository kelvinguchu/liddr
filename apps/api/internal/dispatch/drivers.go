// Package dispatch owns driver availability, offers and matching rides to drivers.
package dispatch

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const minPingInterval = 3 * time.Second

// Errors returned to callers.
var (
	ErrProfileMissing     = errors.New("driver profile does not exist")
	ErrCategoryLocked     = errors.New("vehicle category cannot change after approval")
	ErrNotVerified        = errors.New("driver is not verified")
	ErrSubscriptionNeeded = errors.New("driver subscription is not active")
	ErrDriverBusy         = errors.New("driver already has an active ride")
	ErrDriverOffline      = errors.New("driver is offline")
	ErrInvalidLocation    = errors.New("location is not valid")
	ErrOfferNotFound      = errors.New("offer not found")
	ErrOfferClosed        = errors.New("offer is no longer open")
)

// Config holds the dependencies of a Service.
type Config struct {
	Pool *pgxpool.Pool
	Now  func() time.Time
}

// Service manages drivers and offers.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	now     func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{pool: cfg.Pool, queries: store.New(cfg.Pool), now: cfg.Now}
}

// Profile is a driver's standing.
type Profile struct {
	VehicleCategory    string
	VerificationStatus string
	SubscriptionStatus string
	IsOnline           bool
}

// GetProfile returns a driver's profile.
func (s *Service) GetProfile(ctx context.Context, driverID uuid.UUID) (Profile, error) {
	row, err := s.queries.GetDriver(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrProfileMissing
	}
	if err != nil {
		return Profile{}, fmt.Errorf("load driver: %w", err)
	}
	return Profile{
		VehicleCategory:    row.VehicleCategory,
		VerificationStatus: row.VerificationStatus,
		SubscriptionStatus: row.SubscriptionStatus,
		IsOnline:           row.IsOnline,
	}, nil
}

// SetCategory creates or updates the profile. Approval is tied to a specific
// vehicle, so the category cannot change afterwards.
func (s *Service) SetCategory(ctx context.Context, driverID uuid.UUID, category string) (Profile, error) {
	row, err := s.queries.GetActiveCategoryBySlug(ctx, category)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, rides.ErrCategoryNotFound
	}
	if err != nil {
		return Profile{}, fmt.Errorf("load category: %w", err)
	}
	updated, err := s.queries.UpsertDriverCategory(ctx, store.UpsertDriverCategoryParams{UserID: driverID, VehicleCategoryID: row.ID})
	if err != nil {
		return Profile{}, fmt.Errorf("save driver category: %w", err)
	}
	if updated == 0 {
		return Profile{}, ErrCategoryLocked
	}
	return s.GetProfile(ctx, driverID)
}

// GoOnline makes the driver eligible for offers.
func (s *Service) GoOnline(ctx context.Context, driverID uuid.UUID) error {
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		driver, err := lockDriver(ctx, q, driverID)
		if err != nil {
			return err
		}
		if err := checkEligible(driver); err != nil {
			return err
		}
		busy, err := q.DriverHasActiveRide(ctx, new(driverID))
		if err != nil {
			return fmt.Errorf("check active ride: %w", err)
		}
		if busy {
			return ErrDriverBusy
		}
		return setOnline(ctx, q, driverID, true)
	})
}

// GoOffline stops new offers. An offer already open simply expires.
func (s *Service) GoOffline(ctx context.Context, driverID uuid.UUID) error {
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if _, err := lockDriver(ctx, q, driverID); err != nil {
			return err
		}
		return setOnline(ctx, q, driverID, false)
	})
}

func setOnline(ctx context.Context, q *store.Queries, driverID uuid.UUID, online bool) error {
	if err := q.SetDriverOnline(ctx, store.SetDriverOnlineParams{IsOnline: online, UserID: driverID}); err != nil {
		return fmt.Errorf("set driver online: %w", err)
	}
	return nil
}

func lockDriver(ctx context.Context, q *store.Queries, driverID uuid.UUID) (store.GetDriverForUpdateRow, error) {
	driver, err := q.GetDriverForUpdate(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.GetDriverForUpdateRow{}, ErrProfileMissing
	}
	if err != nil {
		return store.GetDriverForUpdateRow{}, fmt.Errorf("lock driver: %w", err)
	}
	return driver, nil
}

func checkEligible(driver store.GetDriverForUpdateRow) error {
	if driver.VerificationStatus != "approved" {
		return ErrNotVerified
	}
	if driver.SubscriptionStatus != "active" && driver.SubscriptionStatus != "grace" {
		return ErrSubscriptionNeeded
	}
	return nil
}

// UpdateLocation stores the driver's position using a server timestamp. Location
// is collected only while online or on a ride. Excess pings are dropped silently.
func (s *Service) UpdateLocation(ctx context.Context, driverID uuid.UUID, point geo.Point) error {
	if !point.Valid() {
		return ErrInvalidLocation
	}
	now := s.now()
	written, err := s.queries.UpsertDriverLocation(ctx, store.UpsertDriverLocationParams{
		Lat: point.Lat, Lng: point.Lng, Now: now, DriverID: driverID, LimitBefore: now.Add(-minPingInterval),
	})
	if err != nil {
		return fmt.Errorf("save driver location: %w", err)
	}
	if written > 0 {
		return nil
	}

	// Nothing written is either an excess ping or a driver who should not be
	// sending positions at all. Only the second is the client's error.
	driver, err := s.GetProfile(ctx, driverID)
	if err != nil {
		return err
	}
	busy, err := s.queries.DriverHasActiveRide(ctx, new(driverID))
	if err != nil {
		return fmt.Errorf("check active ride: %w", err)
	}
	if !driver.IsOnline && !busy {
		return ErrDriverOffline
	}
	return nil
}
