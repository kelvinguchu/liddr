package httpapi

import (
	"context"
	"time"
)

// ListAuthMethods reports how people can sign in on this deployment.
func (a *API) ListAuthMethods(context.Context, ListAuthMethodsRequestObject) (ListAuthMethodsResponseObject, error) {
	methods := []AuthMethodsMethods{PhoneOtp}
	if a.deps.Auth.EmailEnabled() {
		methods = append(methods, EmailOtp)
	}
	if a.deps.Auth.GoogleEnabled() {
		methods = append(methods, Google)
	}
	return ListAuthMethods200JSONResponse{Methods: methods}, nil
}

// ListRideDeliveries shows what was sent about a ride.
func (a *API) ListRideDeliveries(ctx context.Context, req ListRideDeliveriesRequestObject) (ListRideDeliveriesResponseObject, error) {
	items, err := a.deps.Notifications.ForRide(ctx, req.RideId)
	if err != nil {
		return nil, err
	}
	data := make([]RideDelivery, len(items))
	for i, d := range items {
		data[i] = RideDelivery{Id: d.ID, UserId: d.UserID, EventType: d.EventType, Status: d.Status, PushStatus: d.PushStatus, Attempts: d.Attempts, AckedAt: d.AckedAt, CreatedAt: d.CreatedAt}
	}
	return ListRideDeliveries200JSONResponse{Data: data}, nil
}

// GetWatchdogSummary counts rescued pickups.
func (a *API) GetWatchdogSummary(ctx context.Context, req GetWatchdogSummaryRequestObject) (GetWatchdogSummaryResponseObject, error) {
	hours := int32(24)
	if req.Params.Hours != nil {
		hours = *req.Params.Hours
	}
	counts, err := a.deps.Rides.WatchdogSummary(ctx, time.Now().Add(-time.Duration(hours)*time.Hour))
	if err != nil {
		return nil, err
	}
	return GetWatchdogSummary200JSONResponse{Reassigned: counts.Reassigned, RiderReassigned: counts.RiderReassigned, Cancelled: counts.Cancelled}, nil
}

// GetEnforcementMetrics summarizes penalties.
func (a *API) GetEnforcementMetrics(ctx context.Context, _ GetEnforcementMetricsRequestObject) (GetEnforcementMetricsResponseObject, error) {
	metrics, overdue, err := a.deps.Moderation.Metrics(ctx)
	if err != nil {
		return nil, err
	}
	data := make([]EnforcementMetric, len(metrics))
	for i, m := range metrics {
		data[i] = EnforcementMetric{Action: m.Action, Status: m.Status, Total: m.Total}
	}
	return GetEnforcementMetrics200JSONResponse{Data: data, OverdueSuspensions: overdue}, nil
}

// GetRatingGuardrail reports whether an account has enough ratings to act on.
func (a *API) GetRatingGuardrail(ctx context.Context, req GetRatingGuardrailRequestObject) (GetRatingGuardrailResponseObject, error) {
	g, err := a.deps.Ratings.GuardrailFor(ctx, req.UserId)
	if err != nil {
		return nil, err
	}
	return GetRatingGuardrail200JSONResponse{Recent: g.Recent, Minimum: g.Minimum, WindowDays: g.WindowDays}, nil
}

// ReviewVerificationDocuments applies one decision to many documents.
func (a *API) ReviewVerificationDocuments(ctx context.Context, req ReviewVerificationDocumentsRequestObject) (ReviewVerificationDocumentsResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	results := a.deps.Verification.ReviewDocuments(ctx, req.Body.DocumentIds, string(req.Body.Decision), req.Body.Reason, actor)
	data := make([]BulkReviewResult, len(results))
	for i, r := range results {
		data[i] = BulkReviewResult{DocumentId: r.DocumentID, Ok: r.Err == nil}
		if r.Err != nil {
			code := "INTERNAL_ERROR"
			if p, ok := findProblem(r.Err); ok {
				code = p.code
			}
			data[i].Code = new(code)
		}
	}
	return ReviewVerificationDocuments200JSONResponse{Data: data}, nil
}
