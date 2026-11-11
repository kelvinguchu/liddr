package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	destinationWindow    = time.Hour
	destinationCooldown  = 45 * time.Second
	destinationTTL       = 3 * time.Minute
	destinationFreshness = 2 * time.Minute
	maxDestinationMoves  = 2
	minDestinationDegree = 0.00001
	maxDestinationNotes  = 300
)

var (
	destinationReasons = []string{"rider_changed_plan", "wrong_dropoff_selected", "traffic_or_safety", "intermediate_stop", "other"}
	rejectReasons      = []string{"driver_declined", "unsafe_request", "route_unserviceable", "other"}
)

// DestinationRequest asks to change where a trip ends.
type DestinationRequest struct {
	RideID  uuid.UUID
	RiderID uuid.UUID
	Dropoff geo.Point
	Reason  string
	Notes   *string
}

// DestinationChange is a proposed or settled change.
type DestinationChange struct {
	ID          uuid.UUID
	Dropoff     geo.Point
	OldFareKES  int32
	NewFareKES  int32
	Status      string
	Reason      string
	RequestedAt time.Time
	RespondedAt *time.Time
}

func checkDestinationAllowed(ride store.Ride, now time.Time) error {
	if ride.Status != StatusInProgress || ride.StartedAt == nil || ride.DriverID == nil || ride.ProductType == productShared {
		return ErrInvalidTransition
	}
	if now.Sub(*ride.StartedAt) > destinationWindow {
		return ErrDestinationWindow
	}
	return nil
}

// repriced prices the whole trip as actually driven: pickup to where the driver
// is now, then on to the new destination. The routes come from Google, so this
// runs before any transaction opens.
func (s *Service) repriced(ctx context.Context, ride store.Ride, dropoff geo.Point, now time.Time) (int32, error) {
	location, err := s.queries.GetDriverLocation(ctx, *ride.DriverID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && now.Sub(location.CapturedAt) > destinationFreshness) {
		return 0, ErrLocationUnknown
	}
	if err != nil {
		return 0, fmt.Errorf("load driver location: %w", err)
	}
	rates, err := s.queries.GetCategoryRates(ctx, ride.VehicleCategoryID)
	if err != nil {
		return 0, fmt.Errorf("load rates: %w", err)
	}
	surge, err := s.queries.GetQuoteSurge(ctx, ride.QuoteID)
	if err != nil {
		return 0, fmt.Errorf("load surge: %w", err)
	}
	current := geo.Point{Lat: location.Lat, Lng: location.Lng}
	request := func(from, to geo.Point) maps.RouteRequest {
		return maps.RouteRequest{Origin: from, Destination: to, TravelMode: travelMode(rates.Slug), RoutingPreference: routingPreference(rates.Slug)}
	}
	driven, err := s.routes.ComputeRoute(ctx, request(geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}, current))
	if err != nil {
		return 0, errors.Join(ErrRouteUnavailable, err)
	}
	remaining, err := s.routes.ComputeRoute(ctx, request(current, dropoff))
	if err != nil {
		return 0, errors.Join(ErrRouteUnavailable, err)
	}
	fare := PriceTrip(Rates{
		Slug: rates.Slug, BaseFeeCents: rates.BaseFeeCents, PerKmCents: rates.PricePerKmCents,
		PerMinCents: rates.PricePerMinCents, MinFareCents: rates.MinFareCents, DiscountBps: rates.DiscountBps,
	}, driven.DistanceM+remaining.DistanceM, driven.DurationS+remaining.DurationS, surge)
	return fare.FinalKES, nil
}

// RequestDestination proposes a new destination for the driver to accept. Limits
// are checked again under the lock, because the price was fetched without one.
func (s *Service) RequestDestination(ctx context.Context, req DestinationRequest) (DestinationChange, error) {
	if !req.Dropoff.Valid() || !req.Dropoff.InKenya() {
		return DestinationChange{}, ErrOutsideServiceArea
	}
	if !slices.Contains(destinationReasons, req.Reason) {
		return DestinationChange{}, ErrInvalidReason
	}
	if req.Notes != nil && len(strings.TrimSpace(*req.Notes)) > maxDestinationNotes {
		return DestinationChange{}, ErrInvalidReason
	}
	now := s.now()
	ride, err := s.queries.GetRideFull(ctx, req.RideID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && ride.RiderID != req.RiderID) {
		return DestinationChange{}, ErrRideNotFound
	}
	if err != nil {
		return DestinationChange{}, fmt.Errorf("load ride: %w", err)
	}
	if err := s.checkDestinationRide(ctx, s.queries, ride, req.Dropoff, now); err != nil {
		return DestinationChange{}, err
	}
	newFare, err := s.repriced(ctx, ride, req.Dropoff, now)
	if err != nil {
		return DestinationChange{}, err
	}
	out := DestinationChange{ID: uuid.New(), Dropoff: req.Dropoff, NewFareKES: newFare, Status: "requested", Reason: req.Reason, RequestedAt: now}
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		locked, err := lockRide(ctx, q, req.RideID)
		if err != nil {
			return err
		}
		if err := s.checkDestinationRide(ctx, q, locked, req.Dropoff, now); err != nil {
			return err
		}
		out.OldFareKES = locked.FareKes
		err = q.InsertDestinationChange(ctx, store.InsertDestinationChangeParams{
			ID: out.ID, RideID: locked.ID, RequestedBy: req.RiderID, DriverID: *locked.DriverID,
			OldDropoffLat: locked.DropoffLat, OldDropoffLng: locked.DropoffLng, NewDropoffLat: req.Dropoff.Lat, NewDropoffLng: req.Dropoff.Lng,
			OldFareKes: locked.FareKes, NewFareKes: newFare, ReasonCode: req.Reason, Notes: req.Notes, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert change: %w", err)
		}
		return events.Notify(ctx, q, events.Event{Type: events.TypeDestinationChange, RideID: new(locked.ID), Status: "requested"}, *locked.DriverID)
	})
	if err != nil {
		return DestinationChange{}, err
	}
	return out, nil
}

func (s *Service) checkDestinationRide(ctx context.Context, q *store.Queries, ride store.Ride, dropoff geo.Point, now time.Time) error {
	if err := checkDestinationAllowed(ride, now); err != nil {
		return err
	}
	if abs(ride.DropoffLat-dropoff.Lat) < minDestinationDegree && abs(ride.DropoffLng-dropoff.Lng) < minDestinationDegree {
		return ErrSameDestination
	}
	if _, isSend, err := delivery(ctx, q, ride.ID); err != nil {
		return err
	} else if isSend {
		return ErrInvalidTransition
	}
	if err := q.ExpireStaleDestinationChanges(ctx, store.ExpireStaleDestinationChangesParams{Now: new(now), RideID: ride.ID, StaleBefore: now.Add(-destinationTTL)}); err != nil {
		return fmt.Errorf("expire changes: %w", err)
	}
	count, err := q.CountDestinationChanges(ctx, ride.ID)
	if err != nil {
		return fmt.Errorf("count changes: %w", err)
	}
	if count >= maxDestinationMoves {
		return ErrDestinationLimit
	}
	open, err := q.HasOpenDestinationChange(ctx, ride.ID)
	if err != nil {
		return fmt.Errorf("check open change: %w", err)
	}
	if open {
		return ErrDestinationPending
	}
	latest, err := q.LatestDestinationChangeAt(ctx, ride.ID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("load latest change: %w", err)
	}
	if err == nil && now.Sub(latest) < destinationCooldown {
		return ErrDestinationPending
	}
	return nil
}

func abs(v float64) float64 {
	if v < 0 {
		return -v
	}
	return v
}
