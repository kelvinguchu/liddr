package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Ride statuses.
const (
	StatusSearching      = "searching"
	StatusAccepted       = "accepted"
	StatusDriverArriving = "driver_arriving"
	StatusArrived        = "arrived"
	StatusInProgress     = "in_progress"
	StatusCompleted      = "completed"
	StatusCancelled      = "cancelled"
	StatusNoDrivers      = "no_drivers"
)

// legalTransitions is the ride state machine. Any move not listed is refused.
var legalTransitions = map[string][]string{
	StatusSearching:      {StatusAccepted, StatusCancelled, StatusNoDrivers},
	StatusAccepted:       {StatusDriverArriving, StatusArrived, StatusCancelled},
	StatusDriverArriving: {StatusArrived, StatusCancelled},
	StatusArrived:        {StatusInProgress, StatusCancelled},
	StatusInProgress:     {StatusCompleted, StatusCancelled},
}

// Change is one move through the state machine. Fields that it sets go in
// Fields; Status and ID are filled in by Transition.
type Change struct {
	RideID uuid.UUID
	From   string
	To     string
	Actor  *uuid.UUID
	Reason *string
	Fields store.SetRideStatusParams
	At     time.Time
}

// Transition applies a change and records who made it. The caller must hold the
// ride's row lock.
func Transition(ctx context.Context, q *store.Queries, change Change) error {
	if !slices.Contains(legalTransitions[change.From], change.To) {
		return ErrInvalidTransition
	}
	change.Fields.ID = change.RideID
	change.Fields.Status = change.To
	if err := q.SetRideStatus(ctx, change.Fields); err != nil {
		return fmt.Errorf("set ride status: %w", err)
	}
	err := q.InsertRideEvent(ctx, store.InsertRideEventParams{
		RideID:      change.RideID,
		FromStatus:  new(change.From),
		ToStatus:    change.To,
		ActorUserID: change.Actor,
		Reason:      change.Reason,
		OccurredAt:  change.At,
	})
	if err != nil {
		return fmt.Errorf("record ride event: %w", err)
	}
	return nil
}

// lockRide loads a ride for update. The lock order everywhere is ride, then
// driver, then offer, so that concurrent actions cannot deadlock.
func lockRide(ctx context.Context, q *store.Queries, rideID uuid.UUID) (store.Ride, error) {
	ride, err := q.GetRideForUpdate(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.Ride{}, ErrRideNotFound
	}
	if err != nil {
		return store.Ride{}, fmt.Errorf("lock ride: %w", err)
	}
	return ride, nil
}

func lockDriverRide(ctx context.Context, q *store.Queries, rideID, driverID uuid.UUID) (store.Ride, error) {
	ride, err := lockRide(ctx, q, rideID)
	if err != nil {
		return store.Ride{}, err
	}
	if ride.DriverID == nil || *ride.DriverID != driverID {
		return store.Ride{}, ErrRideNotFound
	}
	return ride, nil
}
