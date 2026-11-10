package httpapi

import (
	"context"
	"time"

	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

// ExportMe returns a copy of the account's own data.
func (a *API) ExportMe(ctx context.Context, _ ExportMeRequestObject) (ExportMeResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	data, err := a.deps.Auth.ExportAccount(ctx, p, requestMeta(ctx))
	if err != nil {
		return nil, err
	}
	return ExportMe200JSONResponse(toAccountExport(p, data)), nil
}

func toAccountExport(p auth.Principal, d auth.AccountExport) AccountExport {
	out := AccountExport{
		GeneratedAt: d.GeneratedAt, Truncated: d.Truncated,
		Profile: ExportProfile{
			Id: p.UserID, Phone: d.Profile.Phone, Email: d.Profile.Email, DisplayName: d.Profile.DisplayName,
			PlateNumber: d.Profile.PlateNumber, AccountStatus: d.Profile.AccountStatus,
			CreatedAt: d.Profile.CreatedAt, PhotoConsentAt: d.Profile.PhotoConsentAt,
		},
		Rides: make([]ExportRide, len(d.Rides)), Payments: make([]ExportPayment, len(d.Payments)),
		Documents: make([]ExportDocument, len(d.Documents)), RatingsGiven: make([]ExportRating, len(d.Ratings)),
		ReportsSubmitted: make([]ExportReport, len(d.Reports)), MessagesSent: make([]ExportMessage, len(d.Messages)),
	}
	for i, r := range d.Rides {
		out.Rides[i] = ExportRide{
			Id: r.ID, Role: ExportRideRole(r.Role), Status: r.Status, FareKes: r.FareKES, RequestedAt: r.RequestedAt,
			Pickup: fromPoint(r.Pickup), Dropoff: fromPoint(r.Dropoff), CompletedAt: r.CompletedAt, CancelledAt: r.CancelledAt,
		}
	}
	for i, x := range d.Payments {
		out.Payments[i] = ExportPayment{Channel: x.Channel, Status: x.Status, AmountKes: x.AmountKES, RequestedAt: x.RequestedAt, PaidAt: x.PaidAt}
	}
	for i, x := range d.Documents {
		out.Documents[i] = ExportDocument{DocumentType: x.DocumentType, Status: x.Status, SubmittedAt: x.SubmittedAt, ReviewedAt: x.ReviewedAt, ExpiresOn: exportDate(x.ExpiresOn)}
	}
	for i, x := range d.Ratings {
		out.RatingsGiven[i] = ExportRating{RideId: x.RideID, Score: x.Score, ReasonTags: x.ReasonTags, Comment: x.Comment, SubmittedAt: x.SubmittedAt}
	}
	for i, x := range d.Reports {
		out.ReportsSubmitted[i] = ExportReport{Category: x.Category, Status: x.Status, Description: x.Description, RideId: x.RideID, CreatedAt: x.CreatedAt}
	}
	for i, x := range d.Messages {
		out.MessagesSent[i] = ExportMessage{RideId: x.RideID, Body: x.Body, CreatedAt: x.CreatedAt}
	}
	return out
}

func exportDate(t *time.Time) *openapi_types.Date {
	if t == nil {
		return nil
	}
	return &openapi_types.Date{Time: *t}
}
