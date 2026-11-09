package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	arrivalRadiusM    = 120
	completionRadiusM = 180
	locationMaxAge    = 2 * time.Minute
)

// driverStep describes one driver action. fields returns the columns it sets,
// given the distance from its geofence target, if it has one.
type driverStep struct {
	from []string
	to   string
	// done lists statuses where the action already happened, so that a client
	// retrying after a lost response gets the ride back instead of an error.
	done   []string
	fields func(now time.Time, distanceM *int32) store.SetRideStatusParams
	fence  func(ride store.Ride) (geo.Point, int32, error)
	// guard refuses the step for reasons beyond the state machine.
	guard func(ctx context.Context, q *store.Queries, ride store.Ride, now time.Time) error
}

// MarkArriving records that the driver is heading to pickup.
func (s *Service) MarkArriving(ctx context.Context, rideID, driverID uuid.UUID) (Ride, error) {
	return s.applyDriverStep(ctx, rideID, driverID, driverStep{
		from: []string{StatusAccepted},
		to:   StatusDriverArriving,
		done: []string{StatusDriverArriving},
		fields: func(now time.Time, _ *int32) store.SetRideStatusParams {
			return store.SetRideStatusParams{ArrivingAt: new(now)}
		},
	})
}

// MarkArrived records arrival, which requires a recent position near pickup.
func (s *Service) MarkArrived(ctx context.Context, rideID, driverID uuid.UUID) (Ride, error) {
	return s.applyDriverStep(ctx, rideID, driverID, driverStep{
		from: []string{StatusAccepted, StatusDriverArriving},
		to:   StatusArrived,
		done: []string{StatusArrived},
		fields: func(now time.Time, distanceM *int32) store.SetRideStatusParams {
			return store.SetRideStatusParams{ArrivedAt: new(now), ArrivalDistanceM: distanceM}
		},
		fence: pickupFence,
	})
}

// StartTrip begins the trip.
func (s *Service) StartTrip(ctx context.Context, rideID, driverID uuid.UUID) (Ride, error) {
	return s.applyDriverStep(ctx, rideID, driverID, driverStep{
		from:  []string{StatusArrived},
		to:    StatusInProgress,
		done:  []string{StatusInProgress},
		guard: startGate,
		fields: func(now time.Time, _ *int32) store.SetRideStatusParams {
			return store.SetRideStatusParams{StartedAt: new(now)}
		},
	})
}

// CompleteTrip ends the trip at the fare fixed by the quote. The driver reports
// only how the rider paid, never how much.
func (s *Service) CompleteTrip(ctx context.Context, rideID, driverID uuid.UUID, paymentMode string) (Ride, error) {
	if paymentMode != "cash_direct" && paymentMode != "mpesa_direct" {
		return Ride{}, ErrInvalidPaymentMode
	}
	return s.applyDriverStep(ctx, rideID, driverID, driverStep{
		from:  []string{StatusInProgress},
		to:    StatusCompleted,
		done:  []string{StatusCompleted},
		guard: completeGate,
		fields: func(now time.Time, distanceM *int32) store.SetRideStatusParams {
			return store.SetRideStatusParams{CompletedAt: new(now), PaymentMode: new(paymentMode), CompletionDistanceM: distanceM}
		},
		fence: func(ride store.Ride) (geo.Point, int32, error) {
			return geo.Point{Lat: ride.DropoffLat, Lng: ride.DropoffLng}, completionRadiusM, ErrTooFarFromDropoff
		},
	})
}

func pickupFence(ride store.Ride) (geo.Point, int32, error) {
	return geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}, arrivalRadiusM, ErrTooFarFromPickup
}

func (s *Service) applyDriverStep(ctx context.Context, rideID, driverID uuid.UUID, step driverStep) (Ride, error) {
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockDriverRide(ctx, q, rideID, driverID)
		if err != nil {
			return err
		}
		if slices.Contains(step.done, ride.Status) {
			return nil
		}
		if !slices.Contains(step.from, ride.Status) {
			return ErrInvalidTransition
		}

		now := s.now()
		if step.guard != nil {
			if err := step.guard(ctx, q, ride, now); err != nil {
				return err
			}
		}
		var distanceM *int32
		if step.fence != nil {
			target, radiusM, farErr := step.fence(ride)
			distance, err := checkFence(ctx, q, driverID, target, radiusM, farErr, now)
			if err != nil {
				return err
			}
			distanceM = new(distance)
		}
		return Transition(ctx, q, Change{
			RideID: ride.ID,
			From:   ride.Status,
			To:     step.to,
			Actor:  new(driverID),
			Fields: step.fields(now, distanceM),
			At:     now,
		})
	})
	if err != nil {
		return Ride{}, err
	}
	return s.Get(ctx, rideID, driverID)
}

// checkFence returns the driver's distance from target, refusing if the position
// is missing, stale or beyond the radius.
func checkFence(ctx context.Context, q *store.Queries, driverID uuid.UUID, target geo.Point, radiusM int32, tooFar error, now time.Time) (int32, error) {
	location, err := q.GetDriverLocation(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, ErrLocationUnknown
	}
	if err != nil {
		return 0, fmt.Errorf("load driver location: %w", err)
	}
	if now.Sub(location.CapturedAt) > locationMaxAge {
		return 0, ErrLocationUnknown
	}
	distance := int32(geo.DistanceM(geo.Point{Lat: location.Lat, Lng: location.Lng}, target) + 0.5)
	if distance > radiusM {
		return 0, tooFar
	}
	return distance, nil
}
