package dispatch

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// Offer is a ride a driver may accept. It holds the pickup but not the dropoff,
// which a driver sees only after committing.
type Offer struct {
	ID                uuid.UUID
	RideID            uuid.UUID
	Pickup            geo.Point
	DistanceToPickupM int32
	FareKES           int32
	ExpiresAt         time.Time
}

// ListOffers returns the driver's open offers.
func (s *Service) ListOffers(ctx context.Context, driverID uuid.UUID) ([]Offer, error) {
	rows, err := s.queries.ListOpenOffersForDriver(ctx, store.ListOpenOffersForDriverParams{DriverID: driverID, Now: s.now()})
	if err != nil {
		return nil, fmt.Errorf("list offers: %w", err)
	}
	offers := make([]Offer, len(rows))
	for i, row := range rows {
		offers[i] = Offer{
			ID:                row.ID,
			RideID:            row.RideID,
			Pickup:            geo.Point{Lat: row.PickupLat, Lng: row.PickupLng},
			DistanceToPickupM: row.DistanceM,
			FareKES:           row.FareKes,
			ExpiresAt:         row.ExpiresAt,
		}
	}
	return offers, nil
}

func (s *Service) offerRide(ctx context.Context, driverID, offerID uuid.UUID) (uuid.UUID, error) {
	owner, err := s.queries.GetOfferOwner(ctx, offerID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && owner.DriverID != driverID) {
		return uuid.Nil, ErrOfferNotFound
	}
	if err != nil {
		return uuid.Nil, fmt.Errorf("load offer: %w", err)
	}
	return owner.RideID, nil
}

// Accept assigns the ride to the driver. Locks are taken ride, driver, offer, the
// same order as every other ride action, so accepting cannot deadlock with them.
func (s *Service) Accept(ctx context.Context, driverID, offerID uuid.UUID) (uuid.UUID, error) {
	rideID, err := s.offerRide(ctx, driverID, offerID)
	if err != nil {
		return uuid.Nil, err
	}
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		ride, err := q.GetRideForUpdate(ctx, rideID)
		if err != nil {
			return fmt.Errorf("lock ride: %w", err)
		}
		driver, err := lockDriver(ctx, q, driverID)
		if err != nil {
			return err
		}
		offer, err := q.GetOfferForUpdate(ctx, offerID)
		if err != nil {
			return fmt.Errorf("lock offer: %w", err)
		}

		now := s.now()
		if offer.Status != "offered" || ride.Status != rides.StatusSearching {
			return ErrOfferClosed
		}
		if !now.Before(offer.ExpiresAt) {
			if err := q.SetOfferStatus(ctx, store.SetOfferStatusParams{Status: "expired", Now: new(now), ID: offerID}); err != nil {
				return fmt.Errorf("expire offer: %w", err)
			}
			return store.Reject(ErrOfferClosed)
		}
		if err := checkEligible(driver); err != nil {
			return err
		}
		busy, err := q.DriverHasActiveRide(ctx, new(driverID))
		if err != nil {
			return fmt.Errorf("check active ride: %w", err)
		}
		if busy {
			return ErrDriverBusy
		}

		if err := q.SetOfferStatus(ctx, store.SetOfferStatusParams{Status: "accepted", Now: new(now), ID: offerID}); err != nil {
			return fmt.Errorf("accept offer: %w", err)
		}
		if err := q.WithdrawOpenOffersForRide(ctx, store.WithdrawOpenOffersForRideParams{Now: new(now), RideID: rideID}); err != nil {
			return fmt.Errorf("withdraw offers: %w", err)
		}
		return rides.Transition(ctx, q, rides.Change{
			RideID: rideID,
			From:   ride.Status,
			To:     rides.StatusAccepted,
			Actor:  new(driverID),
			Fields: store.SetRideStatusParams{DriverID: new(driverID), AcceptedAt: new(now)},
			At:     now,
		})
	})
	if err != nil {
		return uuid.Nil, err
	}
	return rideID, nil
}

// Reject declines an offer and brings the ride's next dispatch forward.
func (s *Service) Reject(ctx context.Context, driverID, offerID uuid.UUID) error {
	rideID, err := s.offerRide(ctx, driverID, offerID)
	if err != nil {
		return err
	}
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if _, err := q.GetRideForUpdate(ctx, rideID); err != nil {
			return fmt.Errorf("lock ride: %w", err)
		}
		offer, err := q.GetOfferForUpdate(ctx, offerID)
		if err != nil {
			return fmt.Errorf("lock offer: %w", err)
		}
		if offer.Status != "offered" {
			return ErrOfferClosed
		}
		now := s.now()
		if err := q.SetOfferStatus(ctx, store.SetOfferStatusParams{Status: "rejected", Now: new(now), ID: offerID}); err != nil {
			return fmt.Errorf("reject offer: %w", err)
		}
		if err := q.MakeDispatchDueNow(ctx, store.MakeDispatchDueNowParams{Now: new(now), ID: rideID}); err != nil {
			return fmt.Errorf("bring dispatch forward: %w", err)
		}
		return nil
	})
}
