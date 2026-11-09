package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// SharedStop is one place the driver goes.
type SharedStop struct {
	MemberID uuid.UUID
	Kind     string
	Point    geo.Point
}

// SharedMember is a passenger as the viewer may see them.
type SharedMember struct {
	ID      uuid.UUID
	Status  string
	IsSelf  bool
	FareKES *int32
}

// SharedTrip describes a shared ride to one of its parties.
type SharedTrip struct {
	RideID      uuid.UUID
	Status      string
	Members     []SharedMember
	Stops       []SharedStop
	EarningsKES *int32
}

// Shared shows a shared ride. The driver sees every stop. A passenger sees only
// their own stops and fare, never where the other person is going.
func (s *Service) Shared(ctx context.Context, rideID, userID uuid.UUID) (SharedTrip, error) {
	ride, err := s.queries.GetRideFull(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return SharedTrip{}, ErrRideNotFound
	}
	if err != nil {
		return SharedTrip{}, fmt.Errorf("load ride: %w", err)
	}
	if ride.ProductType != productShared {
		return SharedTrip{}, ErrNotShared
	}
	members, err := s.queries.ListSharedMembers(ctx, rideID)
	if err != nil {
		return SharedTrip{}, fmt.Errorf("list members: %w", err)
	}
	isDriver := ride.DriverID != nil && *ride.DriverID == userID
	selfIndex := slices.IndexFunc(members, func(m store.ListSharedMembersRow) bool { return m.RiderID == userID })
	if !isDriver && selfIndex < 0 {
		return SharedTrip{}, ErrRideNotFound
	}
	out := SharedTrip{RideID: rideID, Status: ride.Status}
	var legs []sharedLeg
	var picked []bool
	var ids []uuid.UUID
	var earnings int32
	for i, m := range members {
		view := SharedMember{ID: m.ID, Status: m.Status, IsSelf: i == selfIndex}
		if isDriver || i == selfIndex {
			view.FareKES = new(m.FareKes)
		}
		out.Members = append(out.Members, view)
		if m.Status != "cancelled" && m.Status != "no_show" {
			earnings += m.FareKes
		}
		if memberActive(m.Status) {
			legs = append(legs, sharedLeg{pickup: geo.Point{Lat: m.PickupLat, Lng: m.PickupLng}, dropoff: geo.Point{Lat: m.DropoffLat, Lng: m.DropoffLng}})
			picked = append(picked, m.Status == "picked_up")
			ids = append(ids, m.ID)
		}
	}
	if isDriver {
		out.EarningsKES = new(earnings)
	}
	if len(legs) == 0 {
		return out, nil
	}
	for _, st := range planStops(legs[0].pickup, legs, picked) {
		if !isDriver && ids[st.leg] != members[selfIndex].ID {
			continue
		}
		kind := "dropoff"
		if st.pickup {
			kind = "pickup"
		}
		out.Stops = append(out.Stops, SharedStop{MemberID: ids[st.leg], Kind: kind, Point: st.point})
	}
	return out, nil
}
