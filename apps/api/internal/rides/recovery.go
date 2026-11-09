package rides

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	locationStaleAfter  = 120 * time.Second
	lateWaiver          = 300 * time.Second
	noProgressAfter     = 180 * time.Second
	noProgressDeltaM    = 100
	movingAwayAfter     = 120 * time.Second
	movingAwayDeltaM    = 300
	autoReassignAfter   = 420 * time.Second
	fastReassignAfter   = 180 * time.Second
	autoCancelAfter     = 900 * time.Second
	autoCancelMinMoves  = 1
	watchdogInterval    = 15 * time.Second
	watchdogBatch       = 100
	assumedSpeedMPerSec = 5.5

	reasonDriverNotMoving = "driver_not_moving"
)

// Health says whether a driver heading to pickup appears to be coming.
type Health struct {
	LocationStale bool
	Late          bool
	NoProgress    bool
	MovingAway    bool
	Elapsed       time.Duration
	ReassignCount int32
}

// RecommendReassign reports whether any sign of trouble is present.
func (h Health) RecommendReassign() bool {
	return h.LocationStale || h.Late || h.NoProgress || h.MovingAway
}

func (h Health) stuck() bool {
	return h.LocationStale || h.NoProgress || h.MovingAway
}

// RecordAcceptBaseline stores how far the driver was at acceptance, which later
// shows whether they are actually getting closer.
func RecordAcceptBaseline(ctx context.Context, q *store.Queries, ride store.Ride, driverID uuid.UUID) error {
	location, err := q.GetDriverLocation(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("load driver location: %w", err)
	}
	distance := int32(geo.DistanceM(geo.Point{Lat: location.Lat, Lng: location.Lng}, geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}))
	eta := int32(float64(distance) / assumedSpeedMPerSec)
	if err := q.RecordAcceptBaseline(ctx, store.RecordAcceptBaselineParams{DistanceM: new(distance), EtaS: new(eta), ID: ride.ID}); err != nil {
		return fmt.Errorf("record baseline: %w", err)
	}
	return nil
}

func evaluate(ctx context.Context, q *store.Queries, ride store.Ride, now time.Time) (Health, error) {
	var health Health
	if ride.AcceptedAt != nil {
		health.Elapsed = now.Sub(*ride.AcceptedAt)
	}
	health.ReassignCount = ride.ReassignCount
	if ride.PickupEtaSAtAccept != nil {
		health.Late = health.Elapsed >= time.Duration(*ride.PickupEtaSAtAccept)*time.Second+lateWaiver
	}
	if ride.DriverID == nil {
		return health, nil
	}
	location, err := q.GetDriverLocation(ctx, *ride.DriverID)
	if errors.Is(err, pgx.ErrNoRows) {
		health.LocationStale = true
		return health, nil
	}
	if err != nil {
		return health, fmt.Errorf("load driver location: %w", err)
	}
	health.LocationStale = now.Sub(location.CapturedAt) > locationStaleAfter
	if ride.PickupDistanceMAtAccept == nil {
		return health, nil
	}
	remaining := int32(geo.DistanceM(geo.Point{Lat: location.Lat, Lng: location.Lng}, geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}))
	delta := remaining - *ride.PickupDistanceMAtAccept
	// Not yet 100m closer, and not already standing at the pickup.
	health.NoProgress = health.Elapsed >= noProgressAfter && delta >= -noProgressDeltaM && delta < movingAwayDeltaM && remaining > noProgressDeltaM
	health.MovingAway = health.Elapsed >= movingAwayAfter && delta >= movingAwayDeltaM
	return health, nil
}

// PickupHealth reports on the driver coming to this rider.
func (s *Service) PickupHealth(ctx context.Context, rideID, riderID uuid.UUID) (Health, error) {
	ride, err := s.queries.GetRideFull(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && ride.RiderID != riderID) {
		return Health{}, ErrRideNotFound
	}
	if err != nil {
		return Health{}, fmt.Errorf("load ride: %w", err)
	}
	return evaluate(ctx, s.queries, ride, s.now())
}

func reassignable(status string) bool {
	return status == StatusAccepted || status == StatusDriverArriving
}

// Reassign sends a ride back to dispatch when its driver is not coming. The
// rider cannot use this to shop for a closer driver: there must be a real sign
// of trouble. The previous driver keeps their offer row, so is not offered it again.
func (s *Service) Reassign(ctx context.Context, rideID, riderID uuid.UUID) (Ride, error) {
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockRide(ctx, q, rideID)
		if err != nil {
			return err
		}
		if ride.RiderID != riderID {
			return ErrRideNotFound
		}
		if !reassignable(ride.Status) || ride.DriverID == nil {
			return ErrInvalidTransition
		}
		now := s.now()
		health, err := evaluate(ctx, q, ride, now)
		if err != nil {
			return err
		}
		if !health.RecommendReassign() {
			return ErrReassignNotAllowed
		}
		return moveToDispatch(ctx, q, ride, new(riderID), "rider_reassign", now)
	})
	if err != nil {
		return Ride{}, err
	}
	return s.Get(ctx, rideID, riderID)
}

// moveToDispatch releases the driver and searches again.
func moveToDispatch(ctx context.Context, q *store.Queries, ride store.Ride, actor *uuid.UUID, reason string, now time.Time) error {
	err := q.WithdrawAcceptedOffer(ctx, store.WithdrawAcceptedOfferParams{Now: new(now), RideID: ride.ID, DriverID: *ride.DriverID})
	if err != nil {
		return fmt.Errorf("withdraw offer: %w", err)
	}
	// Transition runs while driver_id is still set, so the released driver hears.
	err = Transition(ctx, q, Change{RideID: ride.ID, From: ride.Status, To: StatusSearching, Actor: actor, Reason: new(reason), At: now})
	if err != nil {
		return err
	}
	err = q.ResetRideForDispatch(ctx, store.ResetRideForDispatchParams{Now: new(now), SearchExpiresAt: now.Add(searchTimeout), ID: ride.ID})
	if err != nil {
		return fmt.Errorf("reset ride: %w", err)
	}
	return nil
}

// RunWatchdog rescues rides whose driver is not coming, until ctx ends.
func (s *Service) RunWatchdog(ctx context.Context, logger *slog.Logger) {
	ticker := time.NewTicker(watchdogInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.CheckPickups(ctx); err != nil && ctx.Err() == nil {
				logger.LogAttrs(ctx, slog.LevelError, "pickup watchdog failed", slog.Any("error", err))
			}
		}
	}
}

// CheckPickups inspects rides waiting for their driver.
func (s *Service) CheckPickups(ctx context.Context) error {
	now := s.now()
	ids, err := s.queries.ListRidesAwaitingPickup(ctx, store.ListRidesAwaitingPickupParams{AcceptedBefore: new(now.Add(-movingAwayAfter)), Batch: watchdogBatch})
	if err != nil {
		return fmt.Errorf("list rides: %w", err)
	}
	var errs []error
	for _, id := range ids {
		errs = append(errs, store.InTx(ctx, s.pool, func(q *store.Queries) error { return s.rescue(ctx, q, id, now) }))
	}
	return errors.Join(errs...)
}

func (s *Service) rescue(ctx context.Context, q *store.Queries, id uuid.UUID, now time.Time) error {
	ride, err := q.GetRideForUpdateSkipLocked(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil // Another instance has it, or it just changed.
	}
	if err != nil {
		return fmt.Errorf("lock ride: %w", err)
	}
	if !reassignable(ride.Status) || ride.DriverID == nil {
		return nil
	}
	health, err := evaluate(ctx, q, ride, now)
	if err != nil {
		return err
	}
	if !health.RecommendReassign() {
		return nil
	}
	switch {
	case health.Elapsed >= autoCancelAfter && health.ReassignCount >= autoCancelMinMoves:
		// Recorded as the system's doing. The rider did not cancel this ride.
		if err := WithdrawOffers(ctx, q, ride.ID, now); err != nil {
			return err
		}
		return Transition(ctx, q, Change{
			RideID: ride.ID, From: ride.Status, To: StatusCancelled, Reason: new(reasonDriverNotMoving),
			Fields: store.SetRideStatusParams{CancelledAt: new(now), CancelledBy: new("system"), CancelReason: new(reasonDriverNotMoving)},
			At:     now,
		})
	case health.Elapsed >= autoReassignAfter, health.Elapsed >= fastReassignAfter && health.stuck():
		return moveToDispatch(ctx, q, ride, nil, "pickup_watchdog", now)
	default:
		return nil
	}
}
