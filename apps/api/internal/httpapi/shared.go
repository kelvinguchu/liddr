package httpapi

import "context"

// GetSharedRide shows a shared ride to one of its parties.
func (a *API) GetSharedRide(ctx context.Context, req GetSharedRideRequestObject) (GetSharedRideResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	trip, err := a.deps.Rides.Shared(ctx, req.RideId, actor)
	if err != nil {
		return nil, err
	}
	members := make([]SharedMember, len(trip.Members))
	for i, m := range trip.Members {
		members[i] = SharedMember{Id: m.ID, Status: m.Status, IsSelf: m.IsSelf, FareKes: m.FareKES}
	}
	stops := make([]SharedStop, len(trip.Stops))
	for i, s := range trip.Stops {
		stops[i] = SharedStop{MemberId: s.MemberID, Kind: SharedStopKind(s.Kind), Point: fromPoint(s.Point)}
	}
	return GetSharedRide200JSONResponse{RideId: trip.RideID, Status: trip.Status, Members: members, Stops: stops, EarningsKes: trip.EarningsKES}, nil
}

// CancelSharedMember takes the caller off a shared ride.
func (a *API) CancelSharedMember(ctx context.Context, req CancelSharedMemberRequestObject) (CancelSharedMemberResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.CancelMember(ctx, req.RideId, req.MemberId, actor, req.Body.Reason); err != nil {
		return nil, err
	}
	return CancelSharedMember204Response{}, nil
}

// ArriveSharedMember records reaching a passenger.
func (a *API) ArriveSharedMember(ctx context.Context, req ArriveSharedMemberRequestObject) (ArriveSharedMemberResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.ArriveMember(ctx, req.RideId, req.MemberId, actor); err != nil {
		return nil, err
	}
	return ArriveSharedMember204Response{}, nil
}

// PickUpSharedMember records a passenger getting in.
func (a *API) PickUpSharedMember(ctx context.Context, req PickUpSharedMemberRequestObject) (PickUpSharedMemberResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.PickUpMember(ctx, req.RideId, req.MemberId, actor); err != nil {
		return nil, err
	}
	return PickUpSharedMember204Response{}, nil
}

// DropOffSharedMember records a passenger arriving.
func (a *API) DropOffSharedMember(ctx context.Context, req DropOffSharedMemberRequestObject) (DropOffSharedMemberResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.DropOffMember(ctx, req.RideId, req.MemberId, actor); err != nil {
		return nil, err
	}
	return DropOffSharedMember204Response{}, nil
}

// NoShowSharedMember removes a passenger who never came.
func (a *API) NoShowSharedMember(ctx context.Context, req NoShowSharedMemberRequestObject) (NoShowSharedMemberResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.MarkMemberNoShow(ctx, req.RideId, req.MemberId, actor); err != nil {
		return nil, err
	}
	return NoShowSharedMember204Response{}, nil
}
