package rides

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// minRatedRides is how many rated rides someone needs before their rating is
// shown, so that one bad trip cannot define a newcomer.
const minRatedRides = 10

// driverPhotoTTL keeps the link to a verification selfie short-lived. A rider's
// app gets a new one each time it loads the ride.
const driverPhotoTTL = 5 * time.Minute

// DriverCard tells a rider who is coming.
type DriverCard struct {
	Name            *string
	PlateNumber     *string
	PhotoURL        *string
	VehicleCategory string
	CompletedRides  int32
	Rating          *float64
}

// RiderCard tells a driver who they are collecting.
type RiderCard struct {
	Name   *string
	Rating *float64
}

// signPhoto returns a link to the driver's photo, or nil if they have none.
func (s *Service) signPhoto(key string) (*string, error) {
	if key == "" || s.storage == nil {
		return nil, nil //nolint:nilnil // No photo is a normal state for a driver.
	}
	url, err := s.storage.SignDownload(key, driverPhotoTTL)
	if err != nil {
		return nil, fmt.Errorf("sign driver photo: %w", err)
	}
	return &url, nil
}

// PublicRating returns a rating to one decimal place, or nil while there are
// too few ratings to show.
func PublicRating(centi *int32, count int32) *float64 {
	if centi == nil || count < minRatedRides {
		return nil
	}
	return new(math.Round(float64(*centi)/10) / 10)
}

// attachCard adds the other party's details while the trip is under way, and
// not after it ends. sees means the actor is a rider still on this trip.
func (s *Service) attachCard(ctx context.Context, row store.Ride, ride *Ride, sees, isDriver bool) error {
	if row.DriverID == nil || !isDriverEnRoute(row.Status) {
		return nil
	}
	switch {
	case sees:
		card, err := s.queries.GetDriverCard(ctx, *row.DriverID)
		if err != nil {
			return fmt.Errorf("load driver card: %w", err)
		}
		photo, err := s.signPhoto(card.PhotoKey)
		if err != nil {
			return err
		}
		ride.Driver = &DriverCard{
			Name: card.DisplayName, PlateNumber: card.PlateNumber, VehicleCategory: card.VehicleCategory, PhotoURL: photo,
			CompletedRides: card.CompletedRides, Rating: PublicRating(card.RatingCenti, card.RatingCount),
		}
	case isDriver && row.ProductType != productShared:
		card, err := s.queries.GetRiderCard(ctx, row.RiderID)
		if err != nil {
			return fmt.Errorf("load rider card: %w", err)
		}
		ride.Rider = &RiderCard{Name: card.DisplayName, Rating: PublicRating(card.RatingCenti, card.RatingCount)}
	}
	return nil
}
