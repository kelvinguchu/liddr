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

func lockMember(ctx context.Context, q *store.Queries, rideID, memberID uuid.UUID) (store.GetSharedMemberForUpdateRow, error) {
	member, err := q.GetSharedMemberForUpdate(ctx, store.GetSharedMemberForUpdateParams{ID: memberID, RideID: rideID})
	if errors.Is(err, pgx.ErrNoRows) {
		return member, ErrMemberNotFound
	}
	if err != nil {
		return member, fmt.Errorf("load member: %w", err)
	}
	return member, nil
}

func memberPickup(m store.GetSharedMemberForUpdateRow) geo.Point {
	return geo.Point{Lat: m.PickupLat, Lng: m.PickupLng}
}

func memberDropoff(m store.GetSharedMemberForUpdateRow) geo.Point {
	return geo.Point{Lat: m.DropoffLat, Lng: m.DropoffLng}
}

type memberStep struct {
	fromMember []string
	fromRide   []string
	to         string
	event      string
	target     func(store.GetSharedMemberForUpdateRow) geo.Point
	radiusM    int32
	tooFar     error
	fields     func(store.SetSharedMemberStatusParams, time.Time) store.SetSharedMemberStatusParams
}

// stepMember moves one passenger forward. The driver must be at that person's
// own stop: the old system let a driver tick anyone off from anywhere.
func (s *Service) stepMember(ctx context.Context, rideID, memberID, driverID uuid.UUID, step memberStep) error {
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockDriverRide(ctx, q, rideID, driverID)
		if err != nil {
			return err
		}
		if ride.ProductType != productShared {
			return ErrNotShared
		}
		member, err := lockMember(ctx, q, rideID, memberID)
		if err != nil {
			return err
		}
		if member.Status == step.to {
			return nil
		}
		if !slices.Contains(step.fromRide, ride.Status) || !slices.Contains(step.fromMember, member.Status) {
			return ErrInvalidTransition
		}
		now := s.now()
		if _, err := checkFence(ctx, q, driverID, step.target(member), step.radiusM, step.tooFar, now); err != nil {
			return err
		}
		params := step.fields(store.SetSharedMemberStatusParams{Status: step.to, ID: memberID}, now)
		if err := q.SetSharedMemberStatus(ctx, params); err != nil {
			return fmt.Errorf("update member: %w", err)
		}
		return q.InsertRideEvent(ctx, store.InsertRideEventParams{RideID: rideID, FromStatus: new(ride.Status), ToStatus: ride.Status, ActorUserID: new(driverID), Reason: new(step.event), OccurredAt: now})
	})
}

// ArriveMember records reaching a passenger's pickup.
func (s *Service) ArriveMember(ctx context.Context, rideID, memberID, driverID uuid.UUID) error {
	return s.stepMember(ctx, rideID, memberID, driverID, memberStep{
		fromMember: []string{"requested", "assigned"}, fromRide: []string{StatusArrived, StatusInProgress}, to: "pickup_pending",
		event: "shared_member_arrived", target: memberPickup, radiusM: arrivalRadiusM, tooFar: ErrTooFarFromPickup,
		fields: func(p store.SetSharedMemberStatusParams, now time.Time) store.SetSharedMemberStatusParams {
			p.PickupArrivedAt = new(now)
			return p
		},
	})
}

// PickUpMember records a passenger getting in.
func (s *Service) PickUpMember(ctx context.Context, rideID, memberID, driverID uuid.UUID) error {
	return s.stepMember(ctx, rideID, memberID, driverID, memberStep{
		fromMember: []string{"pickup_pending"}, fromRide: []string{StatusArrived, StatusInProgress}, to: "picked_up",
		event: "shared_member_picked_up", target: memberPickup, radiusM: arrivalRadiusM, tooFar: ErrTooFarFromPickup,
		fields: func(p store.SetSharedMemberStatusParams, now time.Time) store.SetSharedMemberStatusParams {
			p.PickedUpAt = new(now)
			return p
		},
	})
}

// DropOffMember records a passenger arriving.
func (s *Service) DropOffMember(ctx context.Context, rideID, memberID, driverID uuid.UUID) error {
	return s.stepMember(ctx, rideID, memberID, driverID, memberStep{
		fromMember: []string{"picked_up"}, fromRide: []string{StatusInProgress}, to: "dropped_off",
		event: "shared_member_dropped_off", target: memberDropoff, radiusM: completionRadiusM, tooFar: ErrTooFarFromDropoff,
		fields: func(p store.SetSharedMemberStatusParams, now time.Time) store.SetSharedMemberStatusParams {
			p.DroppedOffAt = new(now)
			p.EndedAt = new(now)
			return p
		},
	})
}
