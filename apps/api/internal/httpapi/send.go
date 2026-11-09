package httpapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/send"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// BookDelivery books a Send trip.
func (a *API) BookDelivery(ctx context.Context, req BookDeliveryRequestObject) (BookDeliveryResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	body := req.Body
	r := send.Request{
		SenderID: p.UserID, SenderPhone: p.Phone, QuoteID: body.QuoteId, SenderName: body.SenderName, RecipientName: body.RecipientName,
		RecipientRaw: body.RecipientPhone, Item: body.ItemDescription, Size: string(body.ItemSize), Payer: string(body.Payer),
		Timing: string(body.PaymentTiming), ItemValueKES: body.ItemValueKes, Instructions: body.SpecialInstructions,
		Acknowledged: body.LiabilityAcknowledged != nil && *body.LiabilityAcknowledged,
	}
	ride, err := a.deps.Send.Book(ctx, r)
	if blocked, ok := errors.AsType[*send.BlockedError](err); ok {
		return BookDeliverydefaultJSONResponse{
			Body:       errorBody(ctx, "ITEM_PROHIBITED", strings.Join(blocked.Messages, " ")),
			StatusCode: http.StatusUnprocessableEntity,
		}, nil
	}
	if err != nil {
		return nil, err
	}
	return BookDelivery201JSONResponse(toAPIRide(ride)), nil
}

// GetDelivery loads a delivery for one of its parties.
func (a *API) GetDelivery(ctx context.Context, req GetDeliveryRequestObject) (GetDeliveryResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	v, err := a.deps.Send.Get(ctx, req.RideId, p.UserID, p.Phone)
	if err != nil {
		return nil, err
	}
	return GetDelivery200JSONResponse{
		RideId: v.RideID, SenderName: v.SenderName, RecipientName: v.RecipientName, RecipientPhone: v.RecipientPhone,
		ItemDescription: v.Item, ItemSize: v.Size, Payer: v.Payer, PaymentTiming: v.Timing, SpecialInstructions: v.Instructions,
		Status: v.Status, PickupProofAt: v.PickupProofAt, DropoffProofAt: v.DropoffProofAt, ConfirmedAt: v.ConfirmedAt,
	}, nil
}

// PrepareProofUpload issues a signed URL for a proof photo.
func (a *API) PrepareProofUpload(ctx context.Context, req PrepareProofUploadRequestObject) (PrepareProofUploadResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	upload, err := a.deps.Send.PrepareProof(ctx, req.RideId, p.UserID, string(req.Body.ProofKind), string(req.Body.ContentType), req.Body.SizeBytes)
	if err != nil {
		return nil, err
	}
	return PrepareProofUpload201JSONResponse{UploadId: upload.ID, UploadUrl: upload.URL, Headers: upload.Headers, ExpiresAt: upload.ExpiresAt}, nil
}

// RecordPickupProof attaches the collection photo.
func (a *API) RecordPickupProof(ctx context.Context, req RecordPickupProofRequestObject) (RecordPickupProofResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Send.RecordPickupProof(ctx, req.RideId, p.UserID, req.Body.UploadId); err != nil {
		return nil, err
	}
	return RecordPickupProof204Response{}, nil
}

// RecordDropoffProof attaches the delivery photo.
func (a *API) RecordDropoffProof(ctx context.Context, req RecordDropoffProofRequestObject) (RecordDropoffProofResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Send.RecordDropoffProof(ctx, req.RideId, p.UserID, req.Body.UploadId); err != nil {
		return nil, err
	}
	return RecordDropoffProof204Response{}, nil
}

// ConfirmDeliveryReceipt records that the recipient has the package.
func (a *API) ConfirmDeliveryReceipt(ctx context.Context, req ConfirmDeliveryReceiptRequestObject) (ConfirmDeliveryReceiptResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Send.ConfirmReceipt(ctx, req.RideId, p.Phone); err != nil {
		return nil, err
	}
	return ConfirmDeliveryReceipt204Response{}, nil
}

// DownloadDeliveryProof returns a short-lived, audited link to a proof photo.
func (a *API) DownloadDeliveryProof(ctx context.Context, req DownloadDeliveryProofRequestObject) (DownloadDeliveryProofResponseObject, error) {
	actor, err := staffActor(ctx)
	if err != nil {
		return nil, err
	}
	link, expires, err := a.deps.Send.ProofLink(ctx, req.RideId, string(req.ProofKind), func(ctx context.Context, q *store.Queries, key string, now time.Time) error {
		return q.InsertAuditEventWithTarget(ctx, store.InsertAuditEventWithTargetParams{
			Action: "send.proof_viewed", UserID: new(actor.UserID), RequestID: actor.RequestID, Ip: actor.IP, Target: new("send_proof:" + key), Now: now,
		})
	})
	if err != nil {
		return nil, err
	}
	return DownloadDeliveryProof200JSONResponse{Url: link, ExpiresAt: expires}, nil
}

// ListProhibitedItems lists screening rules.
func (a *API) ListProhibitedItems(ctx context.Context, _ ListProhibitedItemsRequestObject) (ListProhibitedItemsResponseObject, error) {
	items, err := a.deps.Send.ListProhibited(ctx)
	if err != nil {
		return nil, err
	}
	data := make([]ProhibitedItem, len(items))
	for i, item := range items {
		data[i] = ProhibitedItem{Keyword: item.Keyword, Severity: ProhibitedItemSeverity(item.Severity), Message: item.Message, Active: item.Active}
	}
	return ListProhibitedItems200JSONResponse{Data: data}, nil
}

// SaveProhibitedItem adds or changes a screening rule.
func (a *API) SaveProhibitedItem(ctx context.Context, req SaveProhibitedItemRequestObject) (SaveProhibitedItemResponseObject, error) {
	err := a.deps.Send.SaveProhibited(ctx, send.ProhibitedItem{Keyword: req.Body.Keyword, Severity: string(req.Body.Severity), Message: req.Body.Message, Active: req.Body.Active})
	if err != nil {
		return nil, err
	}
	return SaveProhibitedItem204Response{}, nil
}
