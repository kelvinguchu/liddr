package rides

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	quoteTTL          = 3 * time.Minute
	quoteLimitWindow  = time.Minute
	maxQuotesInWindow = 20

	driverFreshness = 30 * time.Second
	demandWindow    = 3 * time.Minute
)

// QuoteRequest asks for a price.
type QuoteRequest struct {
	RiderID  uuid.UUID
	Category string
	Pickup   geo.Point
	Dropoff  geo.Point
}

// Quote is a priced trip.
type Quote struct {
	ID        uuid.UUID
	Fare      Fare
	DistanceM int32
	DurationS int32
	Polyline  string
	ExpiresAt time.Time
}

// CreateQuote prices a trip. The lifetime is fixed here because a rider who
// could extend it could hold a low fare through a demand spike.
func (s *Service) CreateQuote(ctx context.Context, req QuoteRequest) (Quote, error) {
	if !req.Pickup.Valid() || !req.Dropoff.Valid() || !req.Pickup.InKenya() || !req.Dropoff.InKenya() {
		return Quote{}, ErrOutsideServiceArea
	}
	category, err := s.queries.GetActiveCategoryBySlug(ctx, req.Category)
	if errors.Is(err, pgx.ErrNoRows) {
		return Quote{}, ErrCategoryNotFound
	}
	if err != nil {
		return Quote{}, fmt.Errorf("load category: %w", err)
	}

	// Checked first because every quote costs a paid Google request.
	now := s.now()
	recent, err := s.queries.CountRecentQuotes(ctx, store.CountRecentQuotesParams{RiderID: req.RiderID, Since: now.Add(-quoteLimitWindow)})
	if err != nil {
		return Quote{}, fmt.Errorf("count recent quotes: %w", err)
	}
	if recent >= maxQuotesInWindow {
		return Quote{}, ErrRateLimited
	}

	route, err := s.routes.ComputeRoute(ctx, maps.RouteRequest{
		Origin:            req.Pickup,
		Destination:       req.Dropoff,
		TravelMode:        travelMode(category.Slug),
		RoutingPreference: routingPreference(category.Slug),
	})
	if err != nil {
		return Quote{}, errors.Join(ErrRouteUnavailable, err)
	}

	surge, err := s.currentSurge(ctx, category, req.Pickup, now)
	if err != nil {
		return Quote{}, err
	}
	fare := PriceTrip(Rates{
		Slug:         category.Slug,
		BaseFeeCents: category.BaseFeeCents,
		PerKmCents:   category.PricePerKmCents,
		PerMinCents:  category.PricePerMinCents,
		MinFareCents: category.MinFareCents,
		DiscountBps:  category.DiscountBps,
	}, route.DistanceM, route.DurationS, surge)

	quote := Quote{ID: uuid.New(), Fare: fare, DistanceM: route.DistanceM, DurationS: route.DurationS, Polyline: route.Polyline, ExpiresAt: now.Add(quoteTTL)}
	err = s.queries.InsertQuote(ctx, store.InsertQuoteParams{
		ID:                quote.ID,
		RiderID:           req.RiderID,
		VehicleCategoryID: category.ID,
		PickupLat:         req.Pickup.Lat,
		PickupLng:         req.Pickup.Lng,
		DropoffLat:        req.Dropoff.Lat,
		DropoffLng:        req.Dropoff.Lng,
		DistanceM:         route.DistanceM,
		DurationS:         route.DurationS,
		Polyline:          route.Polyline,
		SurgeBps:          fare.SurgeBps,
		SubtotalCents:     fare.SubtotalCents,
		BaseFareKes:       fare.BaseFareKES,
		DiscountKes:       fare.DiscountKES,
		FinalFareKes:      fare.FinalKES,
		ExpiresAt:         quote.ExpiresAt,
		CreatedAt:         now,
	})
	if err != nil {
		return Quote{}, fmt.Errorf("insert quote: %w", err)
	}
	return quote, nil
}

func (s *Service) currentSurge(ctx context.Context, category store.GetActiveCategoryBySlugRow, pickup geo.Point, now time.Time) (int32, error) {
	box := geo.BoxAround(pickup, float64(category.SearchRadiusM))
	available, err := s.queries.CountAvailableDrivers(ctx, store.CountAvailableDriversParams{
		MinLat: box.MinLat, MaxLat: box.MaxLat, MinLng: box.MinLng, MaxLng: box.MaxLng,
		FreshSince:        now.Add(-driverFreshness),
		VehicleCategoryID: category.ID,
	})
	if err != nil {
		return 0, fmt.Errorf("count available drivers: %w", err)
	}
	searching, err := s.queries.CountSearchingRides(ctx, store.CountSearchingRidesParams{
		VehicleCategoryID: category.ID,
		Since:             now.Add(-demandWindow),
		MinLat:            box.MinLat, MaxLat: box.MaxLat, MinLng: box.MinLng, MaxLng: box.MaxLng,
	})
	if err != nil {
		return 0, fmt.Errorf("count searching rides: %w", err)
	}
	return SurgeBps(category.Slug, now, available, searching), nil
}
