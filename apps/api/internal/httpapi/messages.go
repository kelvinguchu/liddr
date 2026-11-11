package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/messages"
)

// ListQuickActions lists canned messages.
func (a *API) ListQuickActions(context.Context, ListQuickActionsRequestObject) (ListQuickActionsResponseObject, error) {
	actions := messages.QuickActions()
	data := make([]QuickAction, len(actions))
	for i, item := range actions {
		data[i] = QuickAction{Code: item.Code, English: item.English, Swahili: item.Swahili}
	}
	return ListQuickActions200JSONResponse{Data: data}, nil
}

func toMessage(m messages.Message) RideMessage {
	return RideMessage{Seq: m.Seq, Id: m.ID, SenderId: m.SenderID, SenderRole: m.SenderRole, MessageType: m.Type, QuickActionCode: m.QuickActionCode, Body: m.Body, ReadAt: m.ReadAt, CreatedAt: m.CreatedAt}
}

// ListRideMessages reads a ride's chat.
func (a *API) ListRideMessages(ctx context.Context, req ListRideMessagesRequestObject) (ListRideMessagesResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	var after int64
	if req.Params.AfterSeq != nil {
		after = *req.Params.AfterSeq
	}
	var limit int32
	if req.Params.Limit != nil {
		limit = *req.Params.Limit
	}
	thread, err := a.deps.Messages.List(ctx, req.RideId, p.UserID, after, limit)
	if err != nil {
		return nil, err
	}
	data := make([]RideMessage, len(thread.Messages))
	for i, m := range thread.Messages {
		data[i] = toMessage(m)
	}
	return ListRideMessages200JSONResponse{Data: data, NextSeq: thread.NextSeq, Unread: thread.Unread}, nil
}

// SendRideMessage sends a chat message.
func (a *API) SendRideMessage(ctx context.Context, req SendRideMessageRequestObject) (SendRideMessageResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	draft := messages.Draft{RideID: req.RideId, SenderID: p.UserID, QuickAction: req.Body.QuickActionCode}
	if req.Body.Body != nil {
		draft.Body = *req.Body.Body
	}
	message, err := a.deps.Messages.Send(ctx, draft)
	if err != nil {
		return nil, err
	}
	return SendRideMessage201JSONResponse(toMessage(message)), nil
}

// MarkRideMessageRead records a read.
func (a *API) MarkRideMessageRead(ctx context.Context, req MarkRideMessageReadRequestObject) (MarkRideMessageReadResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Messages.MarkRead(ctx, req.RideId, req.MessageId, p.UserID); err != nil {
		return nil, err
	}
	return MarkRideMessageRead204Response{}, nil
}

// HideRideMessage hides a message from the caller's view.
func (a *API) HideRideMessage(ctx context.Context, req HideRideMessageRequestObject) (HideRideMessageResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Messages.Hide(ctx, req.RideId, req.MessageId, p.UserID); err != nil {
		return nil, err
	}
	return HideRideMessage204Response{}, nil
}

// ReportRideMessage reports a message.
func (a *API) ReportRideMessage(ctx context.Context, req ReportRideMessageRequestObject) (ReportRideMessageResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	category := ""
	if req.Body.Category != nil {
		category = *req.Body.Category
	}
	id, err := a.deps.Messages.Report(ctx, req.RideId, req.MessageId, p.UserID, category)
	if err != nil {
		return nil, err
	}
	return ReportRideMessage201JSONResponse{ReportId: id}, nil
}
