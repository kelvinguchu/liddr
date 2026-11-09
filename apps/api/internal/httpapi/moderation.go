package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
)

// ListReportCategories lists what can be reported.
func (a *API) ListReportCategories(ctx context.Context, _ ListReportCategoriesRequestObject) (ListReportCategoriesResponseObject, error) {
	categories, err := a.deps.Moderation.Categories(ctx)
	if err != nil {
		return nil, err
	}
	data := make([]ReportCategory, len(categories))
	for i, c := range categories {
		data[i] = ReportCategory{Slug: c.Slug, Label: c.Label, AppliesTo: c.AppliesTo}
	}
	return ListReportCategories200JSONResponse{Data: data}, nil
}

// SubmitReport files a report.
func (a *API) SubmitReport(ctx context.Context, req SubmitReportRequestObject) (SubmitReportResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	filed, err := a.deps.Moderation.Submit(ctx, moderation.Submission{ReporterID: p.UserID, RideID: req.Body.RideId, Category: req.Body.Category, Description: req.Body.Description})
	if err != nil {
		return nil, err
	}
	return SubmitReport201JSONResponse{Id: filed.ID, Status: filed.Status, CreatedAt: filed.CreatedAt}, nil
}

func toReportSummary(r moderation.Report) ReportSummary {
	return ReportSummary{
		Id: r.ID, ReporterId: r.ReporterID, ReportedId: r.ReportedID, Category: r.Category, Status: r.Status,
		Severity: r.Severity, Source: r.Source, IncidentType: r.IncidentType, RideId: r.RideID, CreatedAt: r.CreatedAt,
	}
}

// ListReports returns the review queue.
func (a *API) ListReports(ctx context.Context, req ListReportsRequestObject) (ListReportsResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	reports, err := a.deps.Moderation.ListReports(ctx, req.Params.Status, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]ReportSummary, len(reports))
	for i, r := range reports {
		data[i] = toReportSummary(r)
	}
	return ListReports200JSONResponse{Data: data}, nil
}

// GetReport loads one report.
func (a *API) GetReport(ctx context.Context, req GetReportRequestObject) (GetReportResponseObject, error) {
	report, err := a.deps.Moderation.GetReport(ctx, req.ReportId)
	if err != nil {
		return nil, err
	}
	return GetReport200JSONResponse{Summary: toReportSummary(report), Description: report.Description, Outcome: report.Outcome}, nil
}

// TriageReport claims a report.
func (a *API) TriageReport(ctx context.Context, req TriageReportRequestObject) (TriageReportResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Moderation.Triage(ctx, req.ReportId, string(req.Body.Status), actor.UserID); err != nil {
		return nil, err
	}
	return TriageReport204Response{}, nil
}

// ReviewReport rules on a report.
func (a *API) ReviewReport(ctx context.Context, req ReviewReportRequestObject) (ReviewReportResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	err = a.deps.Moderation.Review(ctx, req.ReportId, moderation.Decision{
		Decision: string(req.Body.Decision), ReasonCode: req.Body.ReasonCode, Notes: req.Body.Notes, EndsAt: req.Body.EndsAt, Actor: actor.UserID,
	})
	if err != nil {
		return nil, err
	}
	return ReviewReport204Response{}, nil
}

func toEnforcement(e moderation.Enforcement) Enforcement {
	return Enforcement{Id: e.ID, UserId: e.UserID, ReportId: e.ReportID, Action: e.Action, Status: e.Status, ReasonCode: e.ReasonCode, StartsAt: e.StartsAt, EndsAt: e.EndsAt, LiftedAt: e.LiftedAt}
}

// ListEnforcements returns penalties.
func (a *API) ListEnforcements(ctx context.Context, req ListEnforcementsRequestObject) (ListEnforcementsResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Moderation.ListEnforcements(ctx, req.Params.Status, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]Enforcement, len(items))
	for i, e := range items {
		data[i] = toEnforcement(e)
	}
	return ListEnforcements200JSONResponse{Data: data}, nil
}

// ApplyEnforcement applies a penalty.
func (a *API) ApplyEnforcement(ctx context.Context, req ApplyEnforcementRequestObject) (ApplyEnforcementResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	out, err := a.deps.Moderation.Apply(ctx, moderation.Penalty{
		UserID: req.Body.UserId, Actor: actor.UserID, Action: string(req.Body.Action), ReasonCode: req.Body.ReasonCode, ReasonText: req.Body.ReasonText, EndsAt: req.Body.EndsAt, Scope: scopeOf(req.Body.Scope),
	})
	if err != nil {
		return nil, err
	}
	return ApplyEnforcement201JSONResponse(toEnforcement(out)), nil
}

func scopeOf(scope *EnforcementRequestScope) string {
	if scope == nil {
		return ""
	}
	return string(*scope)
}

// LiftEnforcement ends a penalty.
func (a *API) LiftEnforcement(ctx context.Context, req LiftEnforcementRequestObject) (LiftEnforcementResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Moderation.Lift(ctx, req.EnforcementId, actor.UserID); err != nil {
		return nil, err
	}
	return LiftEnforcement204Response{}, nil
}
