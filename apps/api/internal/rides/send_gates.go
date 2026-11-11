package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// recipientWait is how long a driver waits for confirmation after photographing
// the delivered package before photo evidence alone is enough.
const recipientWait = 10 * time.Minute

// delivery returns the delivery on a ride, or false for an ordinary ride.
func delivery(ctx context.Context, q *store.Queries, rideID uuid.UUID) (store.GetSendDeliveryForRideRow, bool, error) {
	row, err := q.GetSendDeliveryForRide(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return row, false, nil
	}
	if err != nil {
		return row, false, fmt.Errorf("load delivery: %w", err)
	}
	return row, true, nil
}

func startGate(ctx context.Context, q *store.Queries, ride store.Ride, _ time.Time) error {
	if ride.ProductType == productShared {
		return requireOnBoard(ctx, q, ride.ID)
	}
	row, isSend, err := delivery(ctx, q, ride.ID)
	if err != nil || !isSend {
		return err
	}
	if row.PickupProofAt == nil {
		return ErrPickupProofRequired
	}
	return nil
}

// requireOnBoard stops a shared trip starting with nobody in the vehicle.
func requireOnBoard(ctx context.Context, q *store.Queries, rideID uuid.UUID) error {
	members, err := q.ListSharedMembers(ctx, rideID)
	if err != nil {
		return fmt.Errorf("list members: %w", err)
	}
	if !slices.ContainsFunc(members, func(m store.ListSharedMembersRow) bool { return m.Status == "picked_up" }) {
		return ErrMemberNotOnBoard
	}
	return nil
}

// requireAllDelivered stops a shared trip ending while anyone is still on it.
func requireAllDelivered(ctx context.Context, q *store.Queries, rideID uuid.UUID) error {
	members, err := q.ListSharedMembers(ctx, rideID)
	if err != nil {
		return fmt.Errorf("list members: %w", err)
	}
	if slices.ContainsFunc(members, func(m store.ListSharedMembersRow) bool { return memberActive(m.Status) }) {
		return ErrMembersPending
	}
	return nil
}

func completeGate(ctx context.Context, q *store.Queries, ride store.Ride, now time.Time) error {
	if ride.ProductType == productShared {
		return requireAllDelivered(ctx, q, ride.ID)
	}
	row, isSend, err := delivery(ctx, q, ride.ID)
	if err != nil || !isSend {
		return err
	}
	if row.DropoffProofAt == nil {
		return ErrDropoffProofRequired
	}
	if row.RecipientConfirmedAt == nil && now.Sub(*row.DropoffProofAt) < recipientWait {
		return ErrRecipientPending
	}
	if err := q.MarkDeliveryCompleted(ctx, store.MarkDeliveryCompletedParams{Now: now, RideID: ride.ID}); err != nil {
		return fmt.Errorf("complete delivery: %w", err)
	}
	return nil
}

// checkSenderCancel stops a sender cancelling once the package is with the driver.
func checkSenderCancel(ctx context.Context, q *store.Queries, ride store.Ride) error {
	row, isSend, err := delivery(ctx, q, ride.ID)
	if err != nil || !isSend {
		return err
	}
	if row.PickupProofAt != nil {
		return ErrPackageCollected
	}
	return nil
}
