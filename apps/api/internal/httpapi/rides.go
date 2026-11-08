package httpapi

import (
	"context"
	"errors"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

var errNoPrincipal = errors.New("protected route ran without a principal")

func actorID(ctx context.Context) (uuid.UUID, error) {
	p, ok := principal(ctx)
	if !ok {
		return uuid.Nil, errNoPrincipal
	}
	return p.UserID, nil
}

func toPoint(c Coordinates) geo.Point { return geo.Point{Lat: c.Lat, Lng: c.Lng} }

func fromPoint(p geo.Point) Coordinates { return Coordinates{Lat: p.Lat, Lng: p.Lng} }

func toAPIRide(r rides.Ride) Ride {
	out := Ride{
		Id:          r.ID,
		Status:      RideStatus(r.Status),
		Pickup:      fromPoint(r.Pickup),
		Dropoff:     fromPoint(r.Dropoff),
		FareKes:     r.FareKES,
		RequestedAt: r.RequestedAt,
		DriverId:    r.DriverID,
	}
	if r.DriverLocation != nil {
		out.DriverLocation = new(fromPoint(*r.DriverLocation))
	}
	if r.PaymentMode != nil {
		out.PaymentMode = new(PaymentMode(*r.PaymentMode))
	}
	return out
}

// CreateQuote prices a trip.
func (a *API) CreateQuote(ctx context.Context, req CreateQuoteRequestObject) (CreateQuoteResponseObject, error) {
	rider, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	quote, err := a.deps.Rides.CreateQuote(ctx, rides.QuoteRequest{
		RiderID:  rider,
		Category: req.Body.VehicleCategory,
		Pickup:   toPoint(req.Body.Pickup),
		Dropoff:  toPoint(req.Body.Dropoff),
	})
	if err != nil {
		return nil, err
	}
	return CreateQuote201JSONResponse{
		Id:          quote.ID,
		FareKes:     quote.Fare.FinalKES,
		BaseFareKes: quote.Fare.BaseFareKES,
		DiscountKes: quote.Fare.DiscountKES,
		SurgeBps:    quote.Fare.SurgeBps,
		DistanceM:   quote.DistanceM,
		DurationS:   quote.DurationS,
		Polyline:    quote.Polyline,
		ExpiresAt:   quote.ExpiresAt,
	}, nil
}

// BookRide books a quoted trip.
func (a *API) BookRide(ctx context.Context, req BookRideRequestObject) (BookRideResponseObject, error) {
	rider, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.Book(ctx, rider, req.Body.QuoteId)
	if err != nil {
		return nil, err
	}
	return BookRide201JSONResponse(toAPIRide(ride)), nil
}

// GetRide returns a ride to a participant.
func (a *API) GetRide(ctx context.Context, req GetRideRequestObject) (GetRideResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.Get(ctx, req.RideId, actor)
	if err != nil {
		return nil, err
	}
	return GetRide200JSONResponse(toAPIRide(ride)), nil
}

// CancelRide cancels a ride for a participant.
func (a *API) CancelRide(ctx context.Context, req CancelRideRequestObject) (CancelRideResponseObject, error) {
	actor, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.Cancel(ctx, req.RideId, actor, req.Body.Reason)
	if err != nil {
		return nil, err
	}
	return CancelRide200JSONResponse(toAPIRide(ride)), nil
}

type rideAction func(context.Context, uuid.UUID, uuid.UUID) (rides.Ride, error)

func runRideAction(ctx context.Context, action rideAction, rideID uuid.UUID) (Ride, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return Ride{}, err
	}
	ride, err := action(ctx, rideID, driver)
	if err != nil {
		return Ride{}, err
	}
	return toAPIRide(ride), nil
}

// MarkArriving reports the driver is heading to pickup.
func (a *API) MarkArriving(ctx context.Context, req MarkArrivingRequestObject) (MarkArrivingResponseObject, error) {
	ride, err := runRideAction(ctx, a.deps.Rides.MarkArriving, req.RideId)
	if err != nil {
		return nil, err
	}
	return MarkArriving200JSONResponse(ride), nil
}

// MarkArrived reports arrival at pickup.
func (a *API) MarkArrived(ctx context.Context, req MarkArrivedRequestObject) (MarkArrivedResponseObject, error) {
	ride, err := runRideAction(ctx, a.deps.Rides.MarkArrived, req.RideId)
	if err != nil {
		return nil, err
	}
	return MarkArrived200JSONResponse(ride), nil
}

// StartTrip starts the trip.
func (a *API) StartTrip(ctx context.Context, req StartTripRequestObject) (StartTripResponseObject, error) {
	ride, err := runRideAction(ctx, a.deps.Rides.StartTrip, req.RideId)
	if err != nil {
		return nil, err
	}
	return StartTrip200JSONResponse(ride), nil
}

// MarkNoShow reports the rider did not come.
func (a *API) MarkNoShow(ctx context.Context, req MarkNoShowRequestObject) (MarkNoShowResponseObject, error) {
	ride, err := runRideAction(ctx, a.deps.Rides.MarkNoShow, req.RideId)
	if err != nil {
		return nil, err
	}
	return MarkNoShow200JSONResponse(ride), nil
}

// CompleteTrip completes the trip.
func (a *API) CompleteTrip(ctx context.Context, req CompleteTripRequestObject) (CompleteTripResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.CompleteTrip(ctx, req.RideId, driver, string(req.Body.PaymentMode))
	if err != nil {
		return nil, err
	}
	return CompleteTrip200JSONResponse(toAPIRide(ride)), nil
}

func toAPIProfile(p dispatch.Profile) DriverProfile {
	return DriverProfile{
		VehicleCategory:    p.VehicleCategory,
		VerificationStatus: DriverProfileVerificationStatus(p.VerificationStatus),
		SubscriptionStatus: DriverProfileSubscriptionStatus(p.SubscriptionStatus),
		IsOnline:           p.IsOnline,
	}
}
