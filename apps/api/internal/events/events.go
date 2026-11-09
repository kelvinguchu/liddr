// Package events publishes realtime updates through Postgres notifications.
// Publishing inside a transaction means an update is delivered only if the
// change it describes commits, and never before.
package events

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Channel is the Postgres notification channel.
const Channel = "liddr_events"

// Event types sent to clients.
const (
	TypeRideStatus     = "ride.status"
	TypeOfferCreated   = "offer.created"
	TypeOfferClosed    = "offer.closed"
	TypeDriverLocation = "driver.location"
	TypeResync         = "resync"

	TypeVerificationUpdated = "verification.updated"
	TypeRideMessage         = "ride.message"
	TypeRideMessageRead     = "ride.message_read"
	TypeSendUpdated         = "send.updated"
	TypeDestinationChange   = "destination.change"
)

// Event is what a client receives.
type Event struct {
	Type    string     `json:"type"`
	RideID  *uuid.UUID `json:"ride_id,omitempty"`
	OfferID *uuid.UUID `json:"offer_id,omitempty"`
	Status  string     `json:"status,omitempty"`
	Lat     *float64   `json:"lat,omitempty"`
	Lng     *float64   `json:"lng,omitempty"`
}

// Envelope is an event and the accounts that should receive it.
type Envelope struct {
	To    []uuid.UUID `json:"to"`
	Event Event       `json:"event"`
}

// Publisher can issue a notification, on a transaction or a pool.
type Publisher interface {
	PublishEvent(ctx context.Context, arg store.PublishEventParams) error
}

// Recorder can also write to the durable inbox.
type Recorder interface {
	Publisher
	InsertNotifications(ctx context.Context, arg store.InsertNotificationsParams) error
}

// Notify records event in each recipient's inbox, for push and for a client
// that was offline, and then sends it live. Use it for anything a person must
// not miss. Location and other rapidly superseded updates use Publish.
func Notify(ctx context.Context, r Recorder, event Event, to ...uuid.UUID) error {
	var status *string
	if event.Status != "" {
		status = &event.Status
	}
	err := r.InsertNotifications(ctx, store.InsertNotificationsParams{
		EventType: event.Type, RideID: event.RideID, OfferID: event.OfferID, Status: status, Recipients: to,
	})
	if err != nil {
		return fmt.Errorf("record notification: %w", err)
	}
	return Publish(ctx, r, event, to...)
}

// Publish sends event to recipients. Within a transaction it takes effect on
// commit, and it disappears on rollback.
func Publish(ctx context.Context, p Publisher, event Event, to ...uuid.UUID) error {
	payload, err := json.Marshal(Envelope{To: to, Event: event})
	if err != nil {
		return fmt.Errorf("encode event: %w", err)
	}
	if err := p.PublishEvent(ctx, store.PublishEventParams{Channel: Channel, Payload: string(payload)}); err != nil {
		return fmt.Errorf("publish event: %w", err)
	}
	return nil
}
