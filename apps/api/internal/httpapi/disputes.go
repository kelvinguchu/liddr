package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/disputes"
)

// SubmitDispute raises a dispute.
func (a *API) SubmitDispute(ctx context.Context, req SubmitDisputeRequestObject) (SubmitDisputeResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	filed, err := a.deps.Disputes.Submit(ctx, disputes.Submission{
		RequesterID: p.UserID, RideID: req.Body.RideId, Type: string(req.Body.DisputeType),
		Description: req.Body.Description, RequestedResolution: req.Body.RequestedResolution,
	})
	if err != nil {
		return nil, err
	}
	return SubmitDispute201JSONResponse{Id: filed.ID, Status: filed.Status, CreatedAt: filed.CreatedAt}, nil
}

// ListMyDisputes lists disputes this account may see.
func (a *API) ListMyDisputes(ctx context.Context, req ListMyDisputesRequestObject) (ListMyDisputesResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Disputes.ListMine(ctx, p.UserID, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]MyDispute, len(items))
	for i, d := range items {
		data[i] = MyDispute{Id: d.ID, RideId: d.RideID, DisputeType: d.Type, Status: d.Status, Outcome: d.Outcome, OpenedByMe: d.OpenedByMe, CreatedAt: d.CreatedAt}
	}
	return ListMyDisputes200JSONResponse{Data: data}, nil
}

func toCompensation(c disputes.Compensation) Compensation {
	return Compensation{
		Id: c.ID, ReportId: c.ReportID, RideId: c.RideID, BeneficiaryId: c.BeneficiaryID, CompensationType: c.Type,
		Status: c.Status, AmountKes: c.AmountKES, ProcessingChannel: c.Channel, ProcessingReference: c.Reference,
		ProcessedAt: c.ProcessedAt, CreatedAt: c.CreatedAt,
	}
}

func toCompensations(items []disputes.Compensation) []Compensation {
	data := make([]Compensation, len(items))
	for i, c := range items {
		data[i] = toCompensation(c)
	}
	return data
}

// ListMyCompensations lists money owed to this account.
func (a *API) ListMyCompensations(ctx context.Context, req ListMyCompensationsRequestObject) (ListMyCompensationsResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Disputes.ListForUser(ctx, p.UserID, limit, offset)
	if err != nil {
		return nil, err
	}
	return ListMyCompensations200JSONResponse{Data: toCompensations(items)}, nil
}

// ListDisputes returns the review queue.
func (a *API) ListDisputes(ctx context.Context, req ListDisputesRequestObject) (ListDisputesResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Disputes.ListCases(ctx, req.Params.Status, limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]DisputeCase, len(items))
	for i, c := range items {
		data[i] = DisputeCase{
			Id: c.ID, ReporterId: c.ReporterID, ReportedId: c.ReportedID, RideId: c.RideID, DisputeType: c.Type, Status: c.Status,
			Severity: c.Severity, IncidentType: c.IncidentType, RequestedResolution: c.RequestedResolution, Description: c.Description, CreatedAt: c.CreatedAt,
		}
	}
	return ListDisputes200JSONResponse{Data: data}, nil
}

// ResolveDispute rules on a dispute.
func (a *API) ResolveDispute(ctx context.Context, req ResolveDisputeRequestObject) (ResolveDisputeResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	err = a.deps.Disputes.Resolve(ctx, req.ReportId, disputes.Resolution{Outcome: string(req.Body.Outcome), AmountKES: req.Body.AmountKes, Summary: req.Body.Summary, Actor: actor.UserID})
	if err != nil {
		return nil, err
	}
	return ResolveDispute204Response{}, nil
}

// ListCompensations returns compensation for staff.
func (a *API) ListCompensations(ctx context.Context, req ListCompensationsRequestObject) (ListCompensationsResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Disputes.ListForOps(ctx, req.Params.Status, limit, offset)
	if err != nil {
		return nil, err
	}
	return ListCompensations200JSONResponse{Data: toCompensations(items)}, nil
}

// MarkCompensationPaid records a payout.
func (a *API) MarkCompensationPaid(ctx context.Context, req MarkCompensationPaidRequestObject) (MarkCompensationPaidResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	out, err := a.deps.Disputes.MarkPaid(ctx, req.CompensationId, disputes.Settlement{Channel: string(req.Body.Channel), Reference: req.Body.Reference, Actor: actor.UserID})
	if err != nil {
		return nil, err
	}
	return MarkCompensationPaid200JSONResponse(toCompensation(out)), nil
}

// CancelCompensation withdraws compensation.
func (a *API) CancelCompensation(ctx context.Context, req CancelCompensationRequestObject) (CancelCompensationResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	out, err := a.deps.Disputes.Cancel(ctx, req.CompensationId, actor.UserID)
	if err != nil {
		return nil, err
	}
	return CancelCompensation200JSONResponse(toCompensation(out)), nil
}
