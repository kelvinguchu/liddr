package rides

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	integrityWindow      = 7 * 24 * time.Hour
	strikeThreshold      = 5
	strikeEscalation     = 8
	riderRestrictDays    = 7
	riderEscalationDays  = 14
	driverSuspendDays    = 1
	driverEscalationDays = 3
	freeCancelGrace      = 120 * time.Second
	pickupFarDistanceM   = 2_000
	recentEventLimit     = 20

	roleRider  = "rider"
	roleDriver = "driver"
)

var justifiedDriverReasons = []string{"vehicle_issue", "safety_concern", "emergency"}

type verdict struct {
	chargeable bool
	waiver     *string
}

func waived(code string) verdict { return verdict{waiver: new(code)} }

// classifyRiderCancel decides whether a rider's cancellation was fair to the
// driver. Evidence the driver was not really coming excuses the rider.
func classifyRiderCancel(ride store.Ride, reason string, health Health, pickupDistanceM *int32) verdict {
	far := pickupDistanceM != nil && *pickupDistanceM >= pickupFarDistanceM
	switch {
	case ride.DriverID == nil:
		return waived("unassigned_ride_cancel")
	case reason == "safety_concern" || reason == "emergency":
		return waived("rider_emergency_or_safety")
	case health.Elapsed <= freeCancelGrace:
		return waived("rider_free_cancel_window")
	case health.Late:
		return waived("driver_late")
	case health.LocationStale:
		return waived("driver_location_stale")
	case reason == reasonDriverNotMoving && (health.NoProgress || health.MovingAway):
		return waived("driver_not_moving")
	case reason == "driver_too_far" && far:
		return waived("driver_too_far")
	default:
		return verdict{chargeable: true}
	}
}

func classifyDriverCancel(reason string) verdict {
	if slices.Contains(justifiedDriverReasons, reason) {
		return waived("driver_justified_reason")
	}
	return verdict{chargeable: true}
}

// recordRiderCancel judges and records a rider's cancellation. It must run
// before the ride changes, because the evidence is the state of the pickup.
func (s *Service) recordRiderCancel(ctx context.Context, q *store.Queries, ride store.Ride, reason string, now time.Time) error {
	health, err := evaluate(ctx, q, ride, now)
	if err != nil {
		return err
	}
	distance, err := currentPickupDistance(ctx, q, ride)
	if err != nil {
		return err
	}
	return s.applyStrike(ctx, q, strike{ride: ride.ID, subject: ride.RiderID, role: roleRider, kind: "cancellation", reason: reason, verdict: classifyRiderCancel(ride, reason, health, distance), now: now})
}

func currentPickupDistance(ctx context.Context, q *store.Queries, ride store.Ride) (*int32, error) {
	if ride.DriverID == nil {
		return nil, nil //nolint:nilnil // No driver means no distance, which is not an error.
	}
	location, err := q.GetDriverLocation(ctx, *ride.DriverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil //nolint:nilnil // An unknown position is handled as stale by the caller.
	}
	if err != nil {
		return nil, fmt.Errorf("load driver location: %w", err)
	}
	return new(int32(geo.DistanceM(geo.Point{Lat: location.Lat, Lng: location.Lng}, geo.Point{Lat: ride.PickupLat, Lng: ride.PickupLng}))), nil
}

type strike struct {
	ride    uuid.UUID
	subject uuid.UUID
	role    string
	kind    string
	reason  string
	verdict verdict
	now     time.Time
}

func (s *Service) applyStrike(ctx context.Context, q *store.Queries, st strike) error {
	err := q.InsertIntegrityEvent(ctx, store.InsertIntegrityEventParams{
		RideID: st.ride, SubjectID: st.subject, SubjectRole: st.role, ViolationType: st.kind, ReasonCode: st.reason,
		Chargeable: st.verdict.chargeable, WaiverCode: st.verdict.waiver, Now: st.now,
	})
	if err != nil {
		return fmt.Errorf("record integrity event: %w", err)
	}
	if !st.verdict.chargeable {
		return nil
	}
	if err := q.LockKey(ctx, "integrity:"+st.subject.String()); err != nil {
		return fmt.Errorf("lock subject: %w", err)
	}
	count, err := q.CountChargeableEvents(ctx, store.CountChargeableEventsParams{SubjectID: st.subject, SubjectRole: st.role, Since: st.now.Add(-integrityWindow)})
	if err != nil {
		return fmt.Errorf("count events: %w", err)
	}
	// Exact counts, so that each further cancellation past a threshold does not
	// stack another penalty on the same person.
	var days int
	switch {
	case count == strikeThreshold && st.role == roleRider:
		days = riderRestrictDays
	case count == strikeEscalation && st.role == roleRider:
		days = riderEscalationDays
	case count == strikeThreshold:
		days = driverSuspendDays
	case count == strikeEscalation:
		days = driverEscalationDays
	default:
		return nil
	}
	until := st.now.Add(time.Duration(days) * 24 * time.Hour)
	if st.role == roleRider {
		if err := q.RestrictBooking(ctx, store.RestrictBookingParams{Until: new(until), ID: st.subject}); err != nil {
			return fmt.Errorf("restrict booking: %w", err)
		}
		return nil
	}
	_, err = s.moderation.ApplyInTx(ctx, q, moderation.Penalty{UserID: st.subject, Action: "temporary_suspension", ReasonCode: "driver_chargeable_events", EndsAt: &until})
	if err != nil {
		return fmt.Errorf("suspend driver: %w", err)
	}
	return nil
}

// IntegrityStanding is a user's recent record.
type IntegrityStanding struct {
	RiderStrikes      int64
	DriverStrikes     int64
	Threshold         int32
	BookingRestricted *time.Time
}

// Standing reports a user's cancellation record.
func (s *Service) Standing(ctx context.Context, userID uuid.UUID) (IntegrityStanding, error) {
	since := s.now().Add(-integrityWindow)
	rider, err := s.queries.CountChargeableEvents(ctx, store.CountChargeableEventsParams{SubjectID: userID, SubjectRole: roleRider, Since: since})
	if err != nil {
		return IntegrityStanding{}, fmt.Errorf("count rider events: %w", err)
	}
	driver, err := s.queries.CountChargeableEvents(ctx, store.CountChargeableEventsParams{SubjectID: userID, SubjectRole: roleDriver, Since: since})
	if err != nil {
		return IntegrityStanding{}, fmt.Errorf("count driver events: %w", err)
	}
	until, err := s.queries.GetBookingRestriction(ctx, userID)
	if err != nil {
		return IntegrityStanding{}, fmt.Errorf("load restriction: %w", err)
	}
	out := IntegrityStanding{RiderStrikes: rider, DriverStrikes: driver, Threshold: strikeThreshold}
	if until != nil && s.now().Before(*until) {
		out.BookingRestricted = until
	}
	return out, nil
}

// IntegrityEvent is one strike, for staff.
type IntegrityEvent struct {
	RideID     uuid.UUID
	Role       string
	Kind       string
	Reason     string
	OccurredAt time.Time
}

// RecentStrikes lists a user's strikes in the current window.
func (s *Service) RecentStrikes(ctx context.Context, userID uuid.UUID) ([]IntegrityEvent, error) {
	rows, err := s.queries.ListChargeableEvents(ctx, store.ListChargeableEventsParams{SubjectID: userID, Since: s.now().Add(-integrityWindow), RowLimit: recentEventLimit})
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	out := make([]IntegrityEvent, len(rows))
	for i, r := range rows {
		out[i] = IntegrityEvent{RideID: r.RideID, Role: r.SubjectRole, Kind: r.ViolationType, Reason: r.ReasonCode, OccurredAt: r.OccurredAt}
	}
	return out, nil
}
