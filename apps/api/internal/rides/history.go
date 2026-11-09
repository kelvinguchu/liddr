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

// HistoryItem is one past or current trip. It holds no addresses, because a
// list of them is a map of where someone lives and works.
type HistoryItem struct {
	ID          uuid.UUID
	Status      string
	Category    string
	FareKES     int32
	PaymentMode *string
	RequestedAt time.Time
	CompletedAt *time.Time
	CancelledAt *time.Time
}

// History lists a user's trips. asDriver selects which side of the trips.
func (s *Service) History(ctx context.Context, userID uuid.UUID, asDriver bool, category *string, limit, offset int32) ([]HistoryItem, error) {
	if asDriver {
		rows, err := s.queries.ListRideHistoryForDriver(ctx, store.ListRideHistoryForDriverParams{UserID: new(userID), Category: category, RowLimit: limit, RowOffset: offset})
		if err != nil {
			return nil, fmt.Errorf("list history: %w", err)
		}
		out := make([]HistoryItem, len(rows))
		for i, r := range rows {
			out[i] = HistoryItem{ID: r.ID, Status: r.Status, Category: r.Category, FareKES: r.FareKes, PaymentMode: r.PaymentMode, RequestedAt: r.RequestedAt, CompletedAt: r.CompletedAt, CancelledAt: r.CancelledAt}
		}
		return out, nil
	}
	rows, err := s.queries.ListRideHistoryForRider(ctx, store.ListRideHistoryForRiderParams{UserID: userID, Category: category, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list history: %w", err)
	}
	out := make([]HistoryItem, len(rows))
	for i, r := range rows {
		out[i] = HistoryItem{ID: r.ID, Status: r.Status, Category: r.Category, FareKES: r.FareKes, PaymentMode: r.PaymentMode, RequestedAt: r.RequestedAt, CompletedAt: r.CompletedAt, CancelledAt: r.CancelledAt}
	}
	return out, nil
}

// TimelineEntry is one step in a ride's life.
type TimelineEntry struct {
	From       *string
	To         string
	Reason     *string
	OccurredAt time.Time
}

// Timeline returns a ride's steps to its rider or driver, without who took them.
func (s *Service) Timeline(ctx context.Context, rideID, userID uuid.UUID) ([]TimelineEntry, error) {
	ride, err := s.queries.GetRideFull(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && ride.RiderID != userID && (ride.DriverID == nil || *ride.DriverID != userID)) {
		return nil, ErrRideNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("load ride: %w", err)
	}
	rows, err := s.queries.ListRideEvents(ctx, rideID)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	out := make([]TimelineEntry, len(rows))
	for i, r := range rows {
		out[i] = TimelineEntry{From: r.FromStatus, To: r.ToStatus, Reason: r.Reason, OccurredAt: r.OccurredAt}
	}
	return out, nil
}
