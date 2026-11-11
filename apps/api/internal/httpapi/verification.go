package httpapi

import (
	"context"
	"time"

	"github.com/oapi-codegen/runtime/types"

	"github.com/kelvinguchu/liddr/apps/api/internal/verification"
)

func toDate(value *time.Time) *types.Date {
	if value == nil {
		return nil
	}
	return &types.Date{Time: *value}
}

func toApplication(a verification.Application) VerificationApplication {
	return VerificationApplication{Id: a.ID, Status: a.Status, DecidedAt: a.DecidedAt, DecisionReason: a.DecisionReason, CreatedAt: a.CreatedAt}
}

func toDocument(d verification.Document) VerificationDocument {
	return VerificationDocument{
		Id: d.ID, DocumentType: d.DocumentType, Version: d.Version, Status: d.Status,
		ExpiresOn: toDate(d.ExpiresOn), RejectionReason: d.RejectionReason, CreatedAt: d.CreatedAt,
	}
}

func staffActor(ctx context.Context) (verification.Actor, error) {
	p, ok := principal(ctx)
	if !ok {
		return verification.Actor{}, errNoPrincipal
	}
	meta := requestMeta(ctx)
	return verification.Actor{UserID: p.UserID, RequestID: meta.RequestID, IP: meta.IP}, nil
}

// StartVerification opens an application.
func (a *API) StartVerification(ctx context.Context, req StartVerificationRequestObject) (StartVerificationResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	application, err := a.deps.Verification.StartApplication(ctx, p.UserID, verification.Applicant{Plate: req.Body.PlateNumber, FullName: req.Body.FullName, PhotoConsent: req.Body.PhotoConsent})
	if err != nil {
		return nil, err
	}
	return StartVerification201JSONResponse(toApplication(application)), nil
}

// PrepareVerificationUpload issues a signed upload URL.
func (a *API) PrepareVerificationUpload(ctx context.Context, req PrepareVerificationUploadRequestObject) (PrepareVerificationUploadResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	upload, err := a.deps.Verification.PrepareUpload(ctx, verification.UploadRequest{
		DriverID:     p.UserID,
		DocumentType: req.Body.DocumentType,
		ContentType:  string(req.Body.ContentType),
		SizeBytes:    req.Body.SizeBytes,
	})
	if err != nil {
		return nil, err
	}
	return PrepareVerificationUpload201JSONResponse{UploadId: upload.ID, UploadUrl: upload.URL, Headers: upload.Headers, ExpiresAt: upload.ExpiresAt}, nil
}

// SubmitVerificationDocument records an uploaded file.
func (a *API) SubmitVerificationDocument(ctx context.Context, req SubmitVerificationDocumentRequestObject) (SubmitVerificationDocumentResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	var expiresOn *time.Time
	if req.Body.ExpiresOn != nil {
		expiresOn = new(req.Body.ExpiresOn.Time)
	}
	document, err := a.deps.Verification.SubmitDocument(ctx, p.UserID, req.Body.UploadId, expiresOn)
	if err != nil {
		return nil, err
	}
	return SubmitVerificationDocument201JSONResponse(toDocument(document)), nil
}

// GetVerificationStatus reports progress.
func (a *API) GetVerificationStatus(ctx context.Context, _ GetVerificationStatusRequestObject) (GetVerificationStatusResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	status, err := a.deps.Verification.GetStatus(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	out := GetVerificationStatus200JSONResponse{
		DriverStatus: status.DriverStatus,
		PlateNumber:  status.PlateNumber,
		Requirements: make([]VerificationRequirement, len(status.Requirements)),
	}
	if status.Application != nil {
		out.Application = new(toApplication(*status.Application))
	}
	for i, r := range status.Requirements {
		out.Requirements[i] = VerificationRequirement{DocumentType: r.DocumentType, Label: r.Label, Required: r.Required, RequiresExpiry: r.RequiresExpiry}
		if r.Document != nil {
			out.Requirements[i].Document = new(toDocument(*r.Document))
		}
	}
	return out, nil
}

func toQueueItem(item verification.QueueItem) VerificationQueueItem {
	return VerificationQueueItem{
		Application: toApplication(item.Application), DriverId: item.DriverID,
		DriverStatus: item.DriverStatus, PlateNumber: item.PlateNumber, FullName: item.FullName, PhoneMasked: item.PhoneMasked,
	}
}

func pageOf(limit, offset *int32) (int32, int32) {
	const defaultLimit, maxLimit = 50, 200
	size, start := int32(defaultLimit), int32(0)
	if limit != nil && *limit > 0 && *limit <= maxLimit {
		size = *limit
	}
	if offset != nil && *offset > 0 {
		start = *offset
	}
	return size, start
}

// ListVerificationApplications returns one page of the review queue.
func (a *API) ListVerificationApplications(ctx context.Context, req ListVerificationApplicationsRequestObject) (ListVerificationApplicationsResponseObject, error) {
	limit, offset := pageOf(req.Params.Limit, req.Params.Offset)
	items, err := a.deps.Verification.ListApplications(ctx, string(req.Params.Status), limit, offset)
	if err != nil {
		return nil, err
	}
	data := make([]VerificationQueueItem, len(items))
	for i, item := range items {
		data[i] = toQueueItem(item)
	}
	return ListVerificationApplications200JSONResponse{Data: data}, nil
}

// GetVerificationApplication loads one application.
func (a *API) GetVerificationApplication(ctx context.Context, req GetVerificationApplicationRequestObject) (GetVerificationApplicationResponseObject, error) {
	detail, err := a.deps.Verification.GetApplication(ctx, req.ApplicationId)
	if err != nil {
		return nil, err
	}
	documents := make([]ReviewableDocument, len(detail.Documents))
	for i, d := range detail.Documents {
		documents[i] = ReviewableDocument{Document: toDocument(d.Document), ContentType: d.ContentType, ScanStatus: d.ScanStatus}
	}
	return GetVerificationApplication200JSONResponse{Summary: toQueueItem(detail.QueueItem), Documents: documents}, nil
}

// ReviewVerificationApplication makes the final decision.
func (a *API) ReviewVerificationApplication(ctx context.Context, req ReviewVerificationApplicationRequestObject) (ReviewVerificationApplicationResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Verification.ReviewApplication(ctx, req.ApplicationId, string(req.Body.Decision), req.Body.Reason, actor); err != nil {
		return nil, err
	}
	return ReviewVerificationApplication204Response{}, nil
}

// ReviewVerificationDocument decides on one document.
func (a *API) ReviewVerificationDocument(ctx context.Context, req ReviewVerificationDocumentRequestObject) (ReviewVerificationDocumentResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	if err := a.deps.Verification.ReviewDocument(ctx, req.DocumentId, string(req.Body.Decision), req.Body.Reason, actor); err != nil {
		return nil, err
	}
	return ReviewVerificationDocument204Response{}, nil
}

// DownloadVerificationDocument returns a short-lived, audited link.
func (a *API) DownloadVerificationDocument(ctx context.Context, req DownloadVerificationDocumentRequestObject) (DownloadVerificationDocumentResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	url, expiresAt, err := a.deps.Verification.DownloadURL(ctx, req.DocumentId, actor)
	if err != nil {
		return nil, err
	}
	return DownloadVerificationDocument200JSONResponse{Url: url, ExpiresAt: expiresAt}, nil
}
