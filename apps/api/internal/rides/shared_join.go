package rides

import (
	"cmp"
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

const productShared = "shared"

// tryJoin places a rider on a compatible open trip. Composition is locked once
// a driver accepts, so only trips still searching are considered.
func (s *Service) tryJoin(ctx context.Context, q *store.Queries, quote store.GetQuoteRow, riderID uuid.UUID, now time.Time) (uuid.UUID, bool, error) {
	request := sharedLeg{pickup: geo.Point{Lat: quote.PickupLat, Lng: quote.PickupLng}, dropoff: geo.Point{Lat: quote.DropoffLat, Lng: quote.DropoffLng}}
	rows, err := q.ListSharedCandidates(ctx, store.ListSharedCandidatesParams{VehicleCategoryID: quote.VehicleCategoryID, RiderID: riderID, Since: now.Add(-sharedMaxAge)})
	if err != nil {
		return uuid.Nil, false, fmt.Errorf("list candidates: %w", err)
	}
	type scored struct {
		id    uuid.UUID
		score float64
	}
	var ranked []scored
	for _, row := range rows {
		existing := sharedLeg{pickup: geo.Point{Lat: row.PickupLat, Lng: row.PickupLng}, dropoff: geo.Point{Lat: row.DropoffLat, Lng: row.DropoffLng}}
		if score, ok := compatibility(existing, request, now.Sub(row.RequestedAt)); ok {
			ranked = append(ranked, scored{row.ID, score})
		}
	}
	slices.SortFunc(ranked, func(a, b scored) int { return cmp.Compare(b.score, a.score) })
	for _, candidate := range ranked {
		joined, err := s.joinIfRoom(ctx, q, candidate.id, quote, riderID, request, now)
		if err != nil || joined {
			return candidate.id, joined, err
		}
	}
	return uuid.Nil, false, nil
}

func (s *Service) joinIfRoom(ctx context.Context, q *store.Queries, rideID uuid.UUID, quote store.GetQuoteRow, riderID uuid.UUID, request sharedLeg, now time.Time) (bool, error) {
	ride, err := q.GetRideForUpdateSkipLocked(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil // Another request is joining or the trip just changed.
	}
	if err != nil {
		return false, fmt.Errorf("lock ride: %w", err)
	}
	if ride.Status != StatusSearching {
		return false, nil
	}
	members, err := q.ListSharedMembers(ctx, rideID)
	if err != nil {
		return false, fmt.Errorf("list members: %w", err)
	}
	var legs []sharedLeg
	for _, m := range members {
		if memberActive(m.Status) {
			legs = append(legs, sharedLeg{pickup: geo.Point{Lat: m.PickupLat, Lng: m.PickupLng}, dropoff: geo.Point{Lat: m.DropoffLat, Lng: m.DropoffLng}})
		}
	}
	if len(legs) == 0 || len(legs) >= sharedMaxMembers {
		return false, nil
	}
	if !detourAcceptable(legs[0].pickup, legs, request) {
		return false, nil
	}
	if err := insertMember(ctx, q, rideID, quote, riderID, now); err != nil {
		return false, err
	}
	return true, nil
}

func insertMember(ctx context.Context, q *store.Queries, rideID uuid.UUID, quote store.GetQuoteRow, riderID uuid.UUID, now time.Time) error {
	err := q.InsertSharedMember(ctx, store.InsertSharedMemberParams{
		ID: uuid.New(), RideID: rideID, RiderID: riderID, QuoteID: quote.ID, FareKes: quote.FinalFareKes,
		PickupLat: quote.PickupLat, PickupLng: quote.PickupLng, DropoffLat: quote.DropoffLat, DropoffLng: quote.DropoffLng, Now: now,
	})
	if err != nil {
		return fmt.Errorf("insert member: %w", err)
	}
	return nil
}

func memberActive(status string) bool {
	switch status {
	case "requested", "assigned", "pickup_pending", "picked_up":
		return true
	default:
		return false
	}
}
