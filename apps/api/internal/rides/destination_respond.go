package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// RespondDestination is the driver's answer. Accepting is what changes the fare.
func (s *Service) RespondDestination(ctx context.Context, rideID, changeID, driverID uuid.UUID, accept bool, reason *string) error {
	if reason != nil && !slices.Contains(rejectReasons, *reason) {
		return ErrInvalidReason
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockDriverRide(ctx, q, rideID, driverID)
		if err != nil {
			return err
		}
		if err := checkDestinationAllowed(ride, now); err != nil {
			return err
		}
		change, err := q.GetDestinationChangeForUpdate(ctx, store.GetDestinationChangeForUpdateParams{ID: changeID, RideID: rideID})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (change.DriverID != driverID || change.Status != "requested")) {
			return ErrDestinationNotFound
		}
		if err != nil {
			return fmt.Errorf("load change: %w", err)
		}
		if now.Sub(change.RequestedAt) > destinationTTL {
			if err := q.FinishDestinationChange(ctx, store.FinishDestinationChangeParams{Status: "expired", Now: new(now), ID: changeID}); err != nil {
				return fmt.Errorf("expire change: %w", err)
			}
			return store.Reject(ErrDestinationStale)
		}
		status := "rejected"
		if accept {
			status, reason = "accepted", nil
			err := q.ApplyDestinationChange(ctx, store.ApplyDestinationChangeParams{Lat: change.NewDropoffLat, Lng: change.NewDropoffLng, FareKes: change.NewFareKes, ID: rideID})
			if err != nil {
				return fmt.Errorf("apply change: %w", err)
			}
		}
		if err := q.FinishDestinationChange(ctx, store.FinishDestinationChangeParams{Status: status, Now: new(now), ReasonCode: reason, ID: changeID}); err != nil {
			return fmt.Errorf("finish change: %w", err)
		}
		return events.Notify(ctx, q, events.Event{Type: events.TypeDestinationChange, RideID: new(rideID), Status: status}, ride.RiderID)
	})
}

// ListDestinationChanges returns a ride's changes to its rider or driver.
func (s *Service) ListDestinationChanges(ctx context.Context, rideID, userID uuid.UUID) ([]DestinationChange, error) {
	ride, err := s.queries.GetRideFull(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && ride.RiderID != userID && (ride.DriverID == nil || *ride.DriverID != userID)) {
		return nil, ErrRideNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load ride: %w", err)
	}
	rows, err := s.queries.ListDestinationChanges(ctx, rideID)
	if err != nil {
		return nil, fmt.Errorf("list changes: %w", err)
	}
	out := make([]DestinationChange, len(rows))
	for i, r := range rows {
		out[i] = DestinationChange{ID: r.ID, Dropoff: geo.Point{Lat: r.NewDropoffLat, Lng: r.NewDropoffLng}, OldFareKES: r.OldFareKes, NewFareKES: r.NewFareKes, Status: r.Status, Reason: r.ReasonCode, RequestedAt: r.RequestedAt, RespondedAt: r.RespondedAt}
	}
	return out, nil
}
