package rides

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// MarkMemberNoShow removes a passenger who never came, after the full wait.
func (s *Service) MarkMemberNoShow(ctx context.Context, rideID, memberID, driverID uuid.UUID) error {
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
		if member.Status == "no_show" {
			return nil
		}
		if member.Status != "pickup_pending" || member.PickupArrivedAt == nil {
			return ErrInvalidTransition
		}
		now := s.now()
		if now.Sub(*member.PickupArrivedAt) < noShowWait {
			return ErrNoShowTooEarly
		}
		if _, err := checkFence(ctx, q, driverID, memberPickup(member), arrivalRadiusM, ErrTooFarFromPickup, now); err != nil {
			return err
		}
		if err := s.applyStrike(ctx, q, strike{ride: rideID, subject: member.RiderID, role: roleRider, kind: "no_show", reason: reasonRiderNoShow, verdict: verdict{chargeable: true}, now: now}); err != nil {
			return err
		}
		return s.removeMember(ctx, q, ride, member, "no_show", new(driverID), "driver", reasonRiderNoShow, now)
	})
}

// CancelMember takes one passenger off a trip. Everyone else carries on.
func (s *Service) CancelMember(ctx context.Context, rideID, memberID, riderID uuid.UUID, reason string) error {
	if !slices.Contains(riderCancelReasons, reason) {
		return ErrInvalidReason
	}
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := lockRide(ctx, q, rideID)
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
		if member.RiderID != riderID {
			return ErrMemberNotFound
		}
		return s.cancelMemberLocked(ctx, q, ride, member, riderID, reason, s.now())
	})
}

func (s *Service) cancelMemberLocked(ctx context.Context, q *store.Queries, ride store.Ride, member store.GetSharedMemberForUpdateRow, riderID uuid.UUID, reason string, now time.Time) error {
	if member.Status == "cancelled" {
		return nil
	}
	switch member.Status {
	case "requested", "assigned", "pickup_pending":
	default:
		return ErrInvalidTransition
	}
	health, err := evaluate(ctx, q, ride, now)
	if err != nil {
		return err
	}
	distance, err := currentPickupDistance(ctx, q, ride)
	if err != nil {
		return err
	}
	err = s.applyStrike(ctx, q, strike{ride: ride.ID, subject: riderID, role: roleRider, kind: "cancellation", reason: reason, verdict: classifyRiderCancel(ride, reason, health, distance), now: now})
	if err != nil {
		return err
	}
	return s.removeMember(ctx, q, ride, member, "cancelled", new(riderID), "rider", reason, now)
}

// removeMember ends one passenger and settles what happens to the trip: it
// passes to the remaining passenger, or ends if nobody is left to carry.
func (s *Service) removeMember(ctx context.Context, q *store.Queries, ride store.Ride, member store.GetSharedMemberForUpdateRow, status string, actor *uuid.UUID, side, reason string, now time.Time) error {
	err := q.SetSharedMemberStatus(ctx, store.SetSharedMemberStatusParams{Status: status, EndedAt: new(now), ID: member.ID})
	if err != nil {
		return fmt.Errorf("update member: %w", err)
	}
	members, err := q.ListSharedMembers(ctx, ride.ID)
	if err != nil {
		return fmt.Errorf("list members: %w", err)
	}
	var remaining *store.ListSharedMembersRow
	served := false
	for i := range members {
		switch {
		case memberActive(members[i].Status) && remaining == nil:
			remaining = &members[i]
		case members[i].Status == "dropped_off":
			served = true
		}
	}
	if remaining == nil {
		if served {
			return nil // Everyone left has been delivered. The driver can complete.
		}
		if actor == nil {
			return ErrInvalidTransition
		}
		return cancelLocked(ctx, q, ride, *actor, side, reason, now)
	}
	if ride.RiderID != member.RiderID {
		return nil
	}
	err = q.PromoteSharedRider(ctx, store.PromoteSharedRiderParams{
		RiderID: remaining.RiderID, PickupLat: remaining.PickupLat, PickupLng: remaining.PickupLng,
		DropoffLat: remaining.DropoffLat, DropoffLng: remaining.DropoffLng, FareKes: remaining.FareKes, ID: ride.ID,
	})
	if err != nil {
		return fmt.Errorf("pass trip on: %w", err)
	}
	return nil
}
