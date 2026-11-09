package rides

import (
	"context"
	"slices"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	noShowWait        = 5 * time.Minute
	reasonRiderNoShow = "rider_no_show"
)

var (
	riderCancelReasons = []string{
		"rider_changed_mind", "driver_too_far", "driver_not_moving",
		"cannot_contact_driver", "safety_concern", "emergency",
	}
	driverCancelReasons = []string{"vehicle_issue", "cannot_contact_rider", "safety_concern", "emergency"}

	// A trip under way can be abandoned only for a reason that outweighs
	// stranding the rider.
	driverInProgressReasons = []string{"vehicle_issue", "safety_concern", "emergency"}

	riderCancellable  = []string{StatusSearching, StatusAccepted, StatusDriverArriving, StatusArrived}
	driverCancellable = []string{StatusAccepted, StatusDriverArriving, StatusArrived, StatusInProgress}
)

// Cancel ends a ride for its rider or assigned driver. The caller's side comes
// from the ride itself, never from the request.
func (s *Service) Cancel(ctx context.Context, rideID, actorID uuid.UUID, reason string) (Ride, error) {
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockRide(ctx, q, rideID)
		if err != nil {
			return err
		}

		var side string
		var reasons, cancellable []string
		switch {
		case ride.RiderID == actorID:
			side, reasons, cancellable = "rider", riderCancelReasons, riderCancellable
		case ride.DriverID != nil && *ride.DriverID == actorID:
			side, reasons, cancellable = "driver", driverCancelReasons, driverCancellable
			if ride.Status == StatusInProgress {
				reasons = driverInProgressReasons
			}
		default:
			return ErrRideNotFound
		}

		if ride.Status == StatusCancelled {
			return nil
		}
		if !slices.Contains(cancellable, ride.Status) {
			return ErrInvalidTransition
		}
		if !slices.Contains(reasons, reason) {
			return ErrInvalidReason
		}
		now := s.now()
		if side == "rider" {
			if err := checkSenderCancel(ctx, q, ride); err != nil {
				return err
			}
			if err := s.recordRiderCancel(ctx, q, ride, reason, now); err != nil {
				return err
			}
		} else {
			err := s.applyStrike(ctx, q, strike{ride: ride.ID, subject: actorID, role: roleDriver, kind: "cancellation", reason: reason, verdict: classifyDriverCancel(reason), now: now})
			if err != nil {
				return err
			}
		}
		return cancelLocked(ctx, q, ride, actorID, side, reason, now)
	})
	if err != nil {
		return Ride{}, err
	}
	return s.Get(ctx, rideID, actorID)
}

// MarkNoShow cancels a ride whose rider never came. The driver must still be at
// pickup and have waited out the full period.
func (s *Service) MarkNoShow(ctx context.Context, rideID, driverID uuid.UUID) (Ride, error) {
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockDriverRide(ctx, q, rideID, driverID)
		if err != nil {
			return err
		}
		if ride.Status == StatusCancelled && ride.CancelReason != nil && *ride.CancelReason == reasonRiderNoShow {
			return nil
		}
		if ride.Status != StatusArrived || ride.ArrivedAt == nil {
			return ErrInvalidTransition
		}
		if err := checkSenderCancel(ctx, q, ride); err != nil {
			return err
		}
		now := s.now()
		if now.Sub(*ride.ArrivedAt) < noShowWait {
			return ErrNoShowTooEarly
		}
		target, radiusM, farErr := pickupFence(ride)
		if _, err := checkFence(ctx, q, driverID, target, radiusM, farErr, now); err != nil {
			return err
		}
		err = s.applyStrike(ctx, q, strike{ride: ride.ID, subject: ride.RiderID, role: roleRider, kind: "no_show", reason: reasonRiderNoShow, verdict: verdict{chargeable: true}, now: now})
		if err != nil {
			return err
		}
		return cancelLocked(ctx, q, ride, driverID, "driver", reasonRiderNoShow, now)
	})
	if err != nil {
		return Ride{}, err
	}
	return s.Get(ctx, rideID, driverID)
}

func cancelLocked(ctx context.Context, q *store.Queries, ride store.Ride, actorID uuid.UUID, side, reason string, now time.Time) error {
	if err := WithdrawOffers(ctx, q, ride.ID, now); err != nil {
		return err
	}
	return Transition(ctx, q, Change{
		RideID: ride.ID,
		From:   ride.Status,
		To:     StatusCancelled,
		Actor:  new(actorID),
		Reason: new(reason),
		Fields: store.SetRideStatusParams{CancelledAt: new(now), CancelledBy: new(side), CancelReason: new(reason)},
		At:     now,
	})
}
