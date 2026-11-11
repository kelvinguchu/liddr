package httpapi

import "context"

// GetDriverProfile returns the driver's profile.
func (a *API) GetDriverProfile(ctx context.Context, _ GetDriverProfileRequestObject) (GetDriverProfileResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	profile, err := a.deps.Dispatch.GetProfile(ctx, driver)
	if err != nil {
		return nil, err
	}
	return GetDriverProfile200JSONResponse(toAPIProfile(profile)), nil
}

// SetDriverCategory chooses the driver's vehicle category.
func (a *API) SetDriverCategory(ctx context.Context, req SetDriverCategoryRequestObject) (SetDriverCategoryResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	profile, err := a.deps.Dispatch.SetCategory(ctx, driver, req.Body.VehicleCategory)
	if err != nil {
		return nil, err
	}
	return SetDriverCategory200JSONResponse(toAPIProfile(profile)), nil
}

// GoOnline starts offers.
func (a *API) GoOnline(ctx context.Context, _ GoOnlineRequestObject) (GoOnlineResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Dispatch.GoOnline(ctx, driver); err != nil {
		return nil, err
	}
	return GoOnline204Response{}, nil
}

// GoOffline stops offers.
func (a *API) GoOffline(ctx context.Context, _ GoOfflineRequestObject) (GoOfflineResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Dispatch.GoOffline(ctx, driver); err != nil {
		return nil, err
	}
	return GoOffline204Response{}, nil
}

// UpdateDriverLocation stores the driver's position.
func (a *API) UpdateDriverLocation(ctx context.Context, req UpdateDriverLocationRequestObject) (UpdateDriverLocationResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Dispatch.UpdateLocation(ctx, driver, toPoint(*req.Body)); err != nil {
		return nil, err
	}
	return UpdateDriverLocation204Response{}, nil
}

// ListDriverOffers returns open offers.
func (a *API) ListDriverOffers(ctx context.Context, _ ListDriverOffersRequestObject) (ListDriverOffersResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	offers, err := a.deps.Dispatch.ListOffers(ctx, driver)
	if err != nil {
		return nil, err
	}
	data := make([]Offer, len(offers))
	for i, offer := range offers {
		data[i] = Offer{
			Id:                offer.ID,
			RideId:            offer.RideID,
			Pickup:            fromPoint(offer.Pickup),
			DistanceToPickupM: offer.DistanceToPickupM,
			FareKes:           offer.FareKES,
			ExpiresAt:         offer.ExpiresAt,
			RiderRating:       offer.RiderRating,
		}
	}
	return ListDriverOffers200JSONResponse{Data: data}, nil
}

// AcceptOffer assigns the ride to the driver.
func (a *API) AcceptOffer(ctx context.Context, req AcceptOfferRequestObject) (AcceptOfferResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	rideID, err := a.deps.Dispatch.Accept(ctx, driver, req.OfferId)
	if err != nil {
		return nil, err
	}
	ride, err := a.deps.Rides.Get(ctx, rideID, driver)
	if err != nil {
		return nil, err
	}
	return AcceptOffer200JSONResponse(toAPIRide(ride)), nil
}

// RejectOffer declines an offer.
func (a *API) RejectOffer(ctx context.Context, req RejectOfferRequestObject) (RejectOfferResponseObject, error) {
	driver, err := actorID(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Dispatch.Reject(ctx, driver, req.OfferId); err != nil {
		return nil, err
	}
	return RejectOffer204Response{}, nil
}
