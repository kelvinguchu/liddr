package httpapi

import (
	"context"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
)

// UpdateMe sets the account's name.
func (a *API) UpdateMe(ctx context.Context, req UpdateMeRequestObject) (UpdateMeResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	name, err := a.deps.Auth.SetDisplayName(ctx, p.UserID, req.Body.DisplayName)
	if err != nil {
		return nil, err
	}
	return UpdateMe200JSONResponse{Id: p.UserID, Phone: p.Phone, Roles: toRoles(p.Roles), DisplayName: new(name)}, nil
}

// DeleteMe closes the account.
func (a *API) DeleteMe(ctx context.Context, _ DeleteMeRequestObject) (DeleteMeResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Auth.DeleteAccount(ctx, p, requestMeta(ctx)); err != nil {
		return nil, err
	}
	return DeleteMe204Response{}, nil
}

// GetDriverEarnings summarizes the driver's completed trips.
func (a *API) GetDriverEarnings(ctx context.Context, _ GetDriverEarningsRequestObject) (GetDriverEarningsResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	earnings, err := a.deps.Rides.Earnings(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	days := make([]EarningsDay, len(earnings.Days))
	for i, d := range earnings.Days {
		days[i] = EarningsDay{Date: openapi_types.Date{Time: d.Date}, Trips: d.Trips, TotalKes: d.TotalKES}
	}
	return GetDriverEarnings200JSONResponse{
		Today:         EarningsPeriod{Trips: earnings.Today.Trips, TotalKes: earnings.Today.TotalKES},
		ThisWeek:      EarningsPeriod{Trips: earnings.Week.Trips, TotalKes: earnings.Week.TotalKES},
		LastSevenDays: days,
	}, nil
}

func toDriverCard(c *rides.DriverCard) *DriverCard {
	if c == nil {
		return nil
	}
	return &DriverCard{Name: c.Name, PlateNumber: c.PlateNumber, PhotoUrl: c.PhotoURL, VehicleCategory: c.VehicleCategory, CompletedRides: c.CompletedRides, Rating: c.Rating}
}

func toRiderCard(c *rides.RiderCard) *RiderCard {
	if c == nil {
		return nil
	}
	return &RiderCard{Name: c.Name, Rating: c.Rating}
}
