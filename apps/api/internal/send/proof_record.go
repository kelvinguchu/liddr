package send

import (
	"context"
	"errors"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// RecordPickupProof attaches the collection photo.
func (s *Service) RecordPickupProof(ctx context.Context, rideID, driverID, uploadID uuid.UUID) error {
	upload, err := s.checkUpload(ctx, uploadID, rideID, driverID, kindPickup)
	if err != nil {
		return err
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if _, err := lockAssigned(ctx, q, rideID, driverID, statusArrived, statusUnderway); err != nil {
			return err
		}
		if err := spend(ctx, q, uploadID, now); err != nil {
			return err
		}
		if err := q.RecordPickupProof(ctx, store.RecordPickupProofParams{Key: new(upload.StorageKey), Now: now, RideID: rideID}); err != nil {
			return fmt.Errorf("record proof: %w", err)
		}
		return nil
	})
}

// RecordDropoffProof attaches the delivery photo and asks the recipient to confirm.
func (s *Service) RecordDropoffProof(ctx context.Context, rideID, driverID, uploadID uuid.UUID) error {
	upload, err := s.checkUpload(ctx, uploadID, rideID, driverID, kindDropoff)
	if err != nil {
		return err
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if _, err := lockAssigned(ctx, q, rideID, driverID, statusUnderway); err != nil {
			return err
		}
		row, err := q.GetSendDelivery(ctx, rideID)
		if err != nil {
			return fmt.Errorf("load delivery: %w", err)
		}
		if row.PickupProofAt == nil {
			return ErrPickupProofFirst
		}
		if row.RecipientConfirmedAt != nil {
			return ErrAlreadyConfirmed
		}
		if err := spend(ctx, q, uploadID, now); err != nil {
			return err
		}
		if err := q.RecordDropoffProof(ctx, store.RecordDropoffProofParams{Key: new(upload.StorageKey), Now: new(now), RideID: rideID}); err != nil {
			return fmt.Errorf("record proof: %w", err)
		}
		recipient, err := q.FindUserIDByPhone(ctx, new(row.RecipientPhone))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // No account: the driver's wait and photo are enough.
		}
		if err != nil {
			return fmt.Errorf("find recipient: %w", err)
		}
		return events.Notify(ctx, q, events.Event{Type: events.TypeSendUpdated, RideID: new(rideID), Status: "confirm_delivery"}, recipient)
	})
}

// ConfirmReceipt records that the recipient has the package. The caller's
// verified phone must be the number the sender entered.
func (s *Service) ConfirmReceipt(ctx context.Context, rideID uuid.UUID, phone string) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := q.GetRideDriverAndStatus(ctx, rideID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load ride: %w", err)
		}
		row, err := q.GetSendDelivery(ctx, rideID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load delivery: %w", err)
		}
		if phone == "" || row.RecipientPhone != phone {
			return ErrNotFound
		}
		if row.DropoffProofAt == nil {
			return ErrWrongState
		}
		if row.RecipientConfirmedAt != nil {
			return nil
		}
		if err := q.RecordRecipientConfirmed(ctx, store.RecordRecipientConfirmedParams{Now: now, RideID: rideID}); err != nil {
			return fmt.Errorf("record confirmation: %w", err)
		}
		to := []uuid.UUID{ride.RiderID}
		if ride.DriverID != nil {
			to = append(to, *ride.DriverID)
		}
		return events.Notify(ctx, q, events.Event{Type: events.TypeSendUpdated, RideID: new(rideID), Status: "delivered_confirmed"}, to...)
	})
}
