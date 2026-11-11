package httpapi

import (
	"context"

	"github.com/kelvinguchu/liddr/apps/api/internal/notifications"
)

// ListNotifications returns the inbox.
func (a *API) ListNotifications(ctx context.Context, req ListNotificationsRequestObject) (ListNotificationsResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	includeAcked := req.Params.IncludeAcked != nil && *req.Params.IncludeAcked
	var limit int32
	if req.Params.Limit != nil {
		limit = *req.Params.Limit
	}
	items, err := a.deps.Notifications.List(ctx, p.UserID, includeAcked, limit)
	if err != nil {
		return nil, err
	}
	data := make([]Notification, len(items))
	for i, n := range items {
		data[i] = Notification{Id: n.ID, EventType: n.EventType, RideId: n.RideID, OfferId: n.OfferID, Status: n.Status, AckedAt: n.AckedAt, CreatedAt: n.CreatedAt}
	}
	return ListNotifications200JSONResponse{Data: data}, nil
}

// GetNotificationSummary counts unread notifications.
func (a *API) GetNotificationSummary(ctx context.Context, _ GetNotificationSummaryRequestObject) (GetNotificationSummaryResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	count, err := a.deps.Notifications.UnreadCount(ctx, p.UserID)
	if err != nil {
		return nil, err
	}
	return GetNotificationSummary200JSONResponse{Unread: count}, nil
}

// AckNotification marks a notification read.
func (a *API) AckNotification(ctx context.Context, req AckNotificationRequestObject) (AckNotificationResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Notifications.Ack(ctx, p.UserID, req.NotificationId); err != nil {
		return nil, err
	}
	return AckNotification204Response{}, nil
}

// RegisterPushToken stores this device's token.
func (a *API) RegisterPushToken(ctx context.Context, req RegisterPushTokenRequestObject) (RegisterPushTokenResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	err := a.deps.Notifications.RegisterDevice(ctx, notifications.Device{UserID: p.UserID, FamilyID: p.FamilyID, Token: req.Body.Token, Platform: string(req.Body.Platform)})
	if err != nil {
		return nil, err
	}
	return RegisterPushToken204Response{}, nil
}

// RevokePushToken stops pushes to a device.
func (a *API) RevokePushToken(ctx context.Context, req RevokePushTokenRequestObject) (RevokePushTokenResponseObject, error) {
	p, ok := principal(ctx)
	if !ok {
		return nil, errNoPrincipal
	}
	if err := a.deps.Notifications.RevokeDevice(ctx, p.UserID, req.Body.Token); err != nil {
		return nil, err
	}
	return RevokePushToken204Response{}, nil
}
