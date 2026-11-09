package rides

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Errors returned to callers.
var (
	ErrCategoryNotFound   = errors.New("vehicle category is not available")
	ErrOutsideServiceArea = errors.New("location is outside the service area")
	ErrRouteUnavailable   = errors.New("route could not be calculated")
	ErrRateLimited        = errors.New("too many requests")
	ErrQuoteNotFound      = errors.New("quote not found")
	ErrQuoteExpired       = errors.New("quote has expired")
	ErrActiveRideExists   = errors.New("rider already has an active ride")
	ErrRideNotFound       = errors.New("ride not found")
	ErrInvalidTransition  = errors.New("ride cannot move to that state now")
	ErrInvalidReason      = errors.New("cancellation reason is not allowed")
	ErrInvalidPaymentMode = errors.New("payment mode is not allowed")
	ErrLocationUnknown    = errors.New("driver location is missing or out of date")
	ErrTooFarFromPickup   = errors.New("driver is too far from pickup")
	ErrTooFarFromDropoff  = errors.New("driver is too far from dropoff")
	ErrNoShowTooEarly     = errors.New("waiting period has not ended")

	ErrWrongBookingType     = errors.New("quote cannot be booked this way")
	ErrPickupProofRequired  = errors.New("package photo is required before starting")
	ErrDropoffProofRequired = errors.New("delivery photo is required before completing")
	ErrRecipientPending     = errors.New("waiting for the recipient to confirm")
	ErrPackageCollected     = errors.New("package has already been collected")
)

// RouteFinder computes a driving route.
type RouteFinder interface {
	ComputeRoute(ctx context.Context, req maps.RouteRequest) (maps.Route, error)
}

// Config holds the dependencies of a Service.
type Config struct {
	Pool   *pgxpool.Pool
	Routes RouteFinder
	Now    func() time.Time
}

// Service implements quoting, booking and the trip lifecycle.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	routes  RouteFinder
	now     func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{pool: cfg.Pool, queries: store.New(cfg.Pool), routes: cfg.Routes, now: cfg.Now}
}

// Ride is a ride as shown to one of its participants.
type Ride struct {
	ID             uuid.UUID
	Status         string
	Pickup         geo.Point
	Dropoff        geo.Point
	FareKES        int32
	RequestedAt    time.Time
	DriverID       *uuid.UUID
	DriverLocation *geo.Point
	PaymentMode    *string
}

func toRide(row store.Ride) Ride {
	return Ride{
		ID:          row.ID,
		Status:      row.Status,
		Pickup:      geo.Point{Lat: row.PickupLat, Lng: row.PickupLng},
		Dropoff:     geo.Point{Lat: row.DropoffLat, Lng: row.DropoffLng},
		FareKES:     row.FareKes,
		RequestedAt: row.RequestedAt,
		DriverID:    row.DriverID,
		PaymentMode: row.PaymentMode,
	}
}

// Get returns a ride to its rider or assigned driver. Anyone else is told it
// does not exist, so ride IDs cannot be probed. Only the rider sees the driver's
// position, and only until the driver is released.
func (s *Service) Get(ctx context.Context, rideID, actorID uuid.UUID) (Ride, error) {
	row, err := s.queries.GetRide(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Ride{}, ErrRideNotFound
	}
	if err != nil {
		return Ride{}, fmt.Errorf("load ride: %w", err)
	}
	isDriver := row.DriverID != nil && *row.DriverID == actorID
	if row.RiderID != actorID && !isDriver {
		return Ride{}, ErrRideNotFound
	}

	ride := toRide(row)
	if row.RiderID == actorID && row.DriverID != nil && isDriverEnRoute(row.Status) {
		location, err := s.queries.GetDriverLocation(ctx, *row.DriverID)
		switch {
		case err == nil:
			ride.DriverLocation = &geo.Point{Lat: location.Lat, Lng: location.Lng}
		case !errors.Is(err, pgx.ErrNoRows):
			return Ride{}, fmt.Errorf("load driver location: %w", err)
		}
	}
	return ride, nil
}

func isDriverEnRoute(status string) bool {
	switch status {
	case StatusAccepted, StatusDriverArriving, StatusArrived, StatusInProgress:
		return true
	default:
		return false
	}
}
