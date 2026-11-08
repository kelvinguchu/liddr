package rides

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	searchTimeout     = 3 * time.Minute
	bookingWindow     = time.Hour
	maxBookingsInHour = 10
)

// Book turns a quote into a ride. The fare and route come only from the quote.
// The quote also makes the call idempotent: repeating it returns the same ride,
// so a client retrying on a poor connection cannot book twice.
func (s *Service) Book(ctx context.Context, riderID, quoteID uuid.UUID) (Ride, error) {
	var rideID uuid.UUID
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		// Serializes this rider's bookings so that the limits below are exact.
		if err := q.LockKey(ctx, "ride:book:"+riderID.String()); err != nil {
			return fmt.Errorf("lock rider bookings: %w", err)
		}
		quote, err := q.GetQuote(ctx, quoteID)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && quote.RiderID != riderID) {
			return ErrQuoteNotFound
		}
		if err != nil {
			return fmt.Errorf("load quote: %w", err)
		}

		existing, err := q.GetRideIDByQuote(ctx, quoteID)
		if err == nil {
			rideID = existing
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("find ride for quote: %w", err)
		}

		now := s.now()
		if !now.Before(quote.ExpiresAt) {
			return ErrQuoteExpired
		}
		if !quote.CategoryActive {
			return ErrCategoryNotFound
		}
		if err := checkBookingAllowed(ctx, q, riderID, now); err != nil {
			return err
		}

		rideID = uuid.New()
		err = q.InsertRide(ctx, store.InsertRideParams{
			ID:                rideID,
			RiderID:           riderID,
			QuoteID:           quote.ID,
			VehicleCategoryID: quote.VehicleCategoryID,
			PickupLat:         quote.PickupLat,
			PickupLng:         quote.PickupLng,
			DropoffLat:        quote.DropoffLat,
			DropoffLng:        quote.DropoffLng,
			FareKes:           quote.FinalFareKes,
			SearchExpiresAt:   now.Add(searchTimeout),
			NextDispatchAt:    new(now),
			RequestedAt:       now,
		})
		if err != nil {
			return fmt.Errorf("insert ride: %w", err)
		}
		err = q.InsertRideEvent(ctx, store.InsertRideEventParams{
			RideID:      rideID,
			ToStatus:    StatusSearching,
			ActorUserID: new(riderID),
			OccurredAt:  now,
		})
		if err != nil {
			return fmt.Errorf("record ride event: %w", err)
		}
		return nil
	})
	if err != nil {
		return Ride{}, err
	}
	return s.Get(ctx, rideID, riderID)
}

func checkBookingAllowed(ctx context.Context, q *store.Queries, riderID uuid.UUID, now time.Time) error {
	active, err := q.RiderHasActiveRide(ctx, riderID)
	if err != nil {
		return fmt.Errorf("check active ride: %w", err)
	}
	if active {
		return ErrActiveRideExists
	}
	recent, err := q.CountRecentRides(ctx, store.CountRecentRidesParams{RiderID: riderID, Since: now.Add(-bookingWindow)})
	if err != nil {
		return fmt.Errorf("count recent rides: %w", err)
	}
	if recent >= maxBookingsInHour {
		return ErrRateLimited
	}
	return nil
}
