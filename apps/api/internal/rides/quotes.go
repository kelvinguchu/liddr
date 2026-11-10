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
	// Shared asks for a per-passenger price on a pooled trip.
	Shared bool
}

// Quote is a priced trip.
type Quote struct {
	ID        uuid.UUID
	Fare      Fare
	DistanceM int32
	DurationS int32
	Polyline  string
	ExpiresAt time.Time
	// SoloFareKES is what the trip would cost alone, on a shared quote.
	SoloFareKES *int32
}

// CategoryQuote is one category's price for a trip.
type CategoryQuote struct {
	Category string
	Quote    Quote
}

// category is what pricing needs to know about a vehicle category.
type category struct {
	id       int64
	slug     string
	radiusM  int32
	capacity int32
	rates    Rates
}

// CreateQuote prices a trip. The lifetime is fixed here because a rider who
// could extend it could hold a low fare through a demand spike.
func (s *Service) CreateQuote(ctx context.Context, req QuoteRequest) (Quote, error) {
	if !req.Pickup.Valid() || !req.Dropoff.Valid() || !req.Pickup.InKenya() || !req.Dropoff.InKenya() {
		return Quote{}, ErrOutsideServiceArea
	}
	row, err := s.queries.GetActiveCategoryBySlug(ctx, req.Category)
	if errors.Is(err, pgx.ErrNoRows) {
		return Quote{}, ErrCategoryNotFound
	}
	if err != nil {
		return Quote{}, fmt.Errorf("load category: %w", err)
	}
	cat := category{
		id: row.ID, slug: row.Slug, radiusM: row.SearchRadiusM, capacity: row.Capacity,
		rates: Rates{Slug: row.Slug, BaseFeeCents: row.BaseFeeCents, PerKmCents: row.PricePerKmCents, PerMinCents: row.PricePerMinCents, MinFareCents: row.MinFareCents, DiscountBps: row.DiscountBps},
	}
	if req.Shared && (cat.capacity < sharedMaxMembers || cat.slug == "motorbike" || cat.slug == "electric_motorbike") {
		return Quote{}, ErrSharedNotAvailable
	}
	now := s.now()
	// Checked first because every quote costs a paid Google request.
	if err := s.checkQuoteLimit(ctx, req.RiderID, 1, now); err != nil {
		return Quote{}, err
	}
	route, err := s.route(ctx, cat.slug, req.Pickup, req.Dropoff)
	if err != nil {
		return Quote{}, err
	}
	return s.storeQuote(ctx, cat, req, route, now)
}

// QuoteAll prices a trip in every open category. Categories that travel the
// same way share one route, so a rider comparing options costs at most one
// routing request per travel mode.
func (s *Service) QuoteAll(ctx context.Context, rider uuid.UUID, pickup, dropoff geo.Point) ([]CategoryQuote, error) {
	if !pickup.Valid() || !dropoff.Valid() || !pickup.InKenya() || !dropoff.InKenya() {
		return nil, ErrOutsideServiceArea
	}
	rows, err := s.queries.ListActiveCategories(ctx)
	if err != nil {
		return nil, fmt.Errorf("list categories: %w", err)
	}
	now := s.now()
	if err := s.checkQuoteLimit(ctx, rider, len(rows), now); err != nil {
		return nil, err
	}
	routes := map[string]maps.Route{}
	out := make([]CategoryQuote, 0, len(rows))
	for _, row := range rows {
		cat := category{
			id: row.ID, slug: row.Slug, radiusM: row.SearchRadiusM, capacity: row.Capacity,
			rates: Rates{Slug: row.Slug, BaseFeeCents: row.BaseFeeCents, PerKmCents: row.PricePerKmCents, PerMinCents: row.PricePerMinCents, MinFareCents: row.MinFareCents, DiscountBps: row.DiscountBps},
		}
		mode := travelMode(cat.slug) + "/" + routingPreference(cat.slug)
		route, ok := routes[mode]
		if !ok {
			if route, err = s.route(ctx, cat.slug, pickup, dropoff); err != nil {
				return nil, err
			}
			routes[mode] = route
		}
		quote, err := s.storeQuote(ctx, cat, QuoteRequest{RiderID: rider, Category: cat.slug, Pickup: pickup, Dropoff: dropoff}, route, now)
		if err != nil {
			return nil, err
		}
		out = append(out, CategoryQuote{Category: cat.slug, Quote: quote})
	}
	return out, nil
}

func (s *Service) checkQuoteLimit(ctx context.Context, rider uuid.UUID, wanted int, now time.Time) error {
	recent, err := s.queries.CountRecentQuotes(ctx, store.CountRecentQuotesParams{RiderID: rider, Since: now.Add(-quoteLimitWindow)})
	if err != nil {
		return fmt.Errorf("count recent quotes: %w", err)
	}
	if recent+int64(wanted) > maxQuotesInWindow {
		return ErrRateLimited
	}
	return nil
}

func (s *Service) route(ctx context.Context, slug string, pickup, dropoff geo.Point) (maps.Route, error) {
	route, err := s.routes.ComputeRoute(ctx, maps.RouteRequest{
		Origin: pickup, Destination: dropoff, TravelMode: travelMode(slug), RoutingPreference: routingPreference(slug),
	})
	if err != nil {
		return maps.Route{}, errors.Join(ErrRouteUnavailable, err)
	}
	return route, nil
}

func (s *Service) storeQuote(ctx context.Context, cat category, req QuoteRequest, route maps.Route, now time.Time) (Quote, error) {
	surge, err := s.currentSurge(ctx, cat, req.Pickup, now)
	if err != nil {
		return Quote{}, err
	}
	fare := PriceTrip(cat.rates, route.DistanceM, route.DurationS, surge)
	product, solo := "solo", (*int32)(nil)
	if req.Shared {
		product, solo = productShared, new(fare.FinalKES)
		fare = PriceShared(fare, cat.rates)
	}
	quote := Quote{ID: uuid.New(), Fare: fare, DistanceM: route.DistanceM, DurationS: route.DurationS, Polyline: route.Polyline, ExpiresAt: now.Add(quoteTTL), SoloFareKES: solo}
	err = s.queries.InsertQuote(ctx, store.InsertQuoteParams{
		ID: quote.ID, RiderID: req.RiderID, VehicleCategoryID: cat.id,
		PickupLat: req.Pickup.Lat, PickupLng: req.Pickup.Lng, DropoffLat: req.Dropoff.Lat, DropoffLng: req.Dropoff.Lng,
		DistanceM: route.DistanceM, DurationS: route.DurationS, Polyline: route.Polyline,
		SurgeBps: fare.SurgeBps, SubtotalCents: fare.SubtotalCents, BaseFareKes: fare.BaseFareKES, DiscountKes: fare.DiscountKES, FinalFareKes: fare.FinalKES,
		ExpiresAt: quote.ExpiresAt, CreatedAt: now, ProductType: product, SoloFareKes: solo,
	})
	if err != nil {
		return Quote{}, fmt.Errorf("insert quote: %w", err)
	}
	return quote, nil
}

func (s *Service) currentSurge(ctx context.Context, cat category, pickup geo.Point, now time.Time) (int32, error) {
	box := geo.BoxAround(pickup, float64(cat.radiusM))
	available, err := s.queries.CountAvailableDrivers(ctx, store.CountAvailableDriversParams{
		MinLat: box.MinLat, MaxLat: box.MaxLat, MinLng: box.MinLng, MaxLng: box.MaxLng,
		FreshSince:        now.Add(-driverFreshness),
		VehicleCategoryID: cat.id,
	})
	if err != nil {
		return 0, fmt.Errorf("count available drivers: %w", err)
	}
	searching, err := s.queries.CountSearchingRides(ctx, store.CountSearchingRidesParams{
		VehicleCategoryID: cat.id,
		Since:             now.Add(-demandWindow),
		MinLat:            box.MinLat, MaxLat: box.MaxLat, MinLng: box.MinLng, MaxLng: box.MaxLng,
	})
	if err != nil {
		return 0, fmt.Errorf("count searching rides: %w", err)
	}
	return SurgeBps(cat.slug, now, available, searching), nil
}
