package dispatch

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	tickInterval    = 500 * time.Millisecond
	offersPerWave   = 3
	offerTTL        = 15 * time.Second
	noDriversRetry  = 10 * time.Second
	driverFreshness = 30 * time.Second
)

// radiusStepsPct widens the search on each wave.
var radiusStepsPct = []int32{100, 150, 200, 300}

// Run drives dispatch until ctx ends. All progress is stored on the ride, so a
// restart or crash loses nothing and any instance can pick up any ride.
func (s *Service) Run(ctx context.Context, logger *slog.Logger) {
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.RunDue(ctx); err != nil && !errors.Is(err, context.Canceled) {
				logger.LogAttrs(ctx, slog.LevelError, "dispatch cycle failed", slog.Any("error", err))
			}
		}
	}
}

// RunDue processes every ride whose next dispatch step has come due.
func (s *Service) RunDue(ctx context.Context) error {
	for {
		worked, err := s.dispatchOne(ctx)
		if err != nil || !worked {
			return err
		}
	}
}

func (s *Service) dispatchOne(ctx context.Context) (bool, error) {
	worked := false
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		now := s.now()
		ride, err := q.ClaimDueRide(ctx, new(now))
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("claim ride: %w", err)
		}
		worked = true

		expired, err := q.ExpireOffersForRide(ctx, store.ExpireOffersForRideParams{Now: new(now), RideID: ride.ID})
		if err != nil {
			return fmt.Errorf("expire offers: %w", err)
		}
		for _, offer := range expired {
			if err := events.Publish(ctx, q, events.Event{Type: events.TypeOfferClosed, OfferID: new(offer.ID)}, offer.DriverID); err != nil {
				return err
			}
		}
		earliest, err := q.EarliestOpenOfferExpiry(ctx, ride.ID)
		if err == nil {
			return schedule(ctx, q, ride.ID, earliest, ride.DispatchWave)
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("find open offers: %w", err)
		}

		if !now.Before(ride.SearchExpiresAt) {
			return rides.Transition(ctx, q, rides.Change{RideID: ride.ID, From: ride.Status, To: rides.StatusNoDrivers, At: now})
		}
		return sendWave(ctx, q, ride, now)
	})
	return worked, err
}

func schedule(ctx context.Context, q *store.Queries, rideID uuid.UUID, at time.Time, wave int32) error {
	if err := q.ScheduleDispatch(ctx, store.ScheduleDispatchParams{NextDispatchAt: new(at), DispatchWave: wave, ID: rideID}); err != nil {
		return fmt.Errorf("schedule dispatch: %w", err)
	}
	return nil
}

type candidate struct {
	driverID  uuid.UUID
	distanceM int32
	rating    float64
}

func sendWave(ctx context.Context, q *store.Queries, ride store.ClaimDueRideRow, now time.Time) error {
	step := radiusStepsPct[min(int(ride.DispatchWave), len(radiusStepsPct)-1)]
	radiusM := float64(ride.SearchRadiusM) * float64(step) / 100
	pickup := geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}
	box := geo.BoxAround(pickup, radiusM)

	rows, err := q.ListDriverCandidates(ctx, store.ListDriverCandidatesParams{
		MinLat: box.MinLat, MaxLat: box.MaxLat, MinLng: box.MinLng, MaxLng: box.MaxLng,
		FreshSince:        now.Add(-driverFreshness),
		VehicleCategoryID: ride.VehicleCategoryID,
		RideID:            ride.ID,
	})
	if err != nil {
		return fmt.Errorf("list candidates: %w", err)
	}

	candidates := make([]candidate, 0, len(rows))
	for _, row := range rows {
		distance := geo.DistanceM(pickup, geo.Point{Lat: row.Lat, Lng: row.Lng})
		if distance <= radiusM {
			candidates = append(candidates, candidate{driverID: row.DriverID, distanceM: int32(distance), rating: ratingScore(row.RatingCenti, row.RatingCount)})
		}
	}
	slices.SortFunc(candidates, compareCandidates)

	sent := 0
	expiresAt := now.Add(offerTTL)
	for _, c := range candidates {
		if sent == offersPerWave {
			break
		}
		// A driver who took another offer a moment ago conflicts and is skipped.
		offerID := uuid.New()
		inserted, err := q.InsertOffer(ctx, store.InsertOfferParams{
			ID: offerID, RideID: ride.ID, DriverID: c.driverID, DistanceM: c.distanceM, OfferedAt: now, ExpiresAt: expiresAt,
		})
		if err != nil {
			return fmt.Errorf("insert offer: %w", err)
		}
		if inserted == 0 {
			continue
		}
		if err := events.Notify(ctx, q, events.Event{Type: events.TypeOfferCreated, OfferID: new(offerID), RideID: new(ride.ID)}, c.driverID); err != nil {
			return err
		}
		sent++
	}

	if sent == 0 {
		return schedule(ctx, q, ride.ID, now.Add(noDriversRetry), ride.DispatchWave+1)
	}
	return schedule(ctx, q, ride.ID, expiresAt, ride.DispatchWave+1)
}
