package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

// GetPickupHealth reports on the driver coming to this rider.
func (a *API) GetPickupHealth(ctx context.Context, req GetPickupHealthRequestObject) (GetPickupHealthResponseObject, error) {
	rider, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	h, err := a.deps.Rides.PickupHealth(ctx, req.RideId, rider)
	if err != nil {
		return nil, err
	}
	return GetPickupHealth200JSONResponse{LocationStale: h.LocationStale, Late: h.Late, NoProgress: h.NoProgress, MovingAway: h.MovingAway, RecommendReassign: h.RecommendReassign()}, nil
}

// ReassignRide finds another driver.
func (a *API) ReassignRide(ctx context.Context, req ReassignRideRequestObject) (ReassignRideResponseObject, error) {
	rider, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.Reassign(ctx, req.RideId, rider)
	if err != nil {
		return nil, err
	}
	return ReassignRide200JSONResponse(toAPIRide(ride)), nil
}

func toDestinationChange(c rides.DestinationChange) DestinationChange {
	return DestinationChange{
		Id: c.ID, Dropoff: Coordinates{Lat: c.Dropoff.Lat, Lng: c.Dropoff.Lng}, OldFareKes: c.OldFareKES, NewFareKes: c.NewFareKES,
		Status: c.Status, ReasonCode: c.Reason, RequestedAt: c.RequestedAt, RespondedAt: c.RespondedAt,
	}
}

// ListDestinationChanges lists a ride's changes.
func (a *API) ListDestinationChanges(ctx context.Context, req ListDestinationChangesRequestObject) (ListDestinationChangesResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	items, err := a.deps.Rides.ListDestinationChanges(ctx, req.RideId, actor)
	if err != nil {
		return nil, err
	}
	data := make([]DestinationChange, len(items))
	for i, c := range items {
		data[i] = toDestinationChange(c)
	}
	return ListDestinationChanges200JSONResponse{Data: data}, nil
}

// RequestDestinationChange proposes a new destination.
func (a *API) RequestDestinationChange(ctx context.Context, req RequestDestinationChangeRequestObject) (RequestDestinationChangeResponseObject, error) {
	rider, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	change, err := a.deps.Rides.RequestDestination(ctx, rides.DestinationRequest{
		RideID: req.RideId, RiderID: rider, Dropoff: toPoint(req.Body.Dropoff), Reason: string(req.Body.ReasonCode), Notes: req.Body.Notes,
	})
	if err != nil {
		return nil, err
	}
	return RequestDestinationChange201JSONResponse(toDestinationChange(change)), nil
}

// AcceptDestinationChange accepts a new destination.
func (a *API) AcceptDestinationChange(ctx context.Context, req AcceptDestinationChangeRequestObject) (AcceptDestinationChangeResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Rides.RespondDestination(ctx, req.RideId, req.ChangeId, driver, true, nil); err != nil {
		return nil, err
	}
	return AcceptDestinationChange204Response{}, nil
}

// RejectDestinationChange declines a new destination.
func (a *API) RejectDestinationChange(ctx context.Context, req RejectDestinationChangeRequestObject) (RejectDestinationChangeResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	var reason *string
	if req.Body.ReasonCode != nil {
		reason = new(string(*req.Body.ReasonCode))
	}
	if err := a.deps.Rides.RespondDestination(ctx, req.RideId, req.ChangeId, driver, false, reason); err != nil {
		return nil, err
	}
	return RejectDestinationChange204Response{}, nil
}

// ListRideHistory lists a user's trips.
func (a *API) ListRideHistory(ctx context.Context, req ListRideHistoryRequestObject) (ListRideHistoryResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Rides.History(ctx, p.UserID, req.Params.As == "driver", req.Params.Category, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]RideHistoryItem, len(items))
	for i, r := range items {
		data[i] = RideHistoryItem{Id: r.ID, Status: r.Status, Category: r.Category, FareKes: r.FareKES, PaymentMode: r.PaymentMode, RequestedAt: r.RequestedAt, CompletedAt: r.CompletedAt, CancelledAt: r.CancelledAt}
	}
	return ListRideHistory200JSONResponse{Data: data}, nil
}

// ListRideEvents lists the steps of a ride.
func (a *API) ListRideEvents(ctx context.Context, req ListRideEventsRequestObject) (ListRideEventsResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	items, err := a.deps.Rides.Timeline(ctx, req.RideId, actor)
	if err != nil {
		return nil, err
	}
	data := make([]RideTimelineEntry, len(items))
	for i, e := range items {
		data[i] = RideTimelineEntry{FromStatus: e.From, ToStatus: e.To, Reason: e.Reason, OccurredAt: e.OccurredAt}
	}
	return ListRideEvents200JSONResponse{Data: data}, nil
}
