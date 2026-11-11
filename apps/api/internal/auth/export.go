package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/geo"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	exportAction   = "account.exported"
	exportsPerDay  = 3
	exportRowLimit = 20_000
)

// ErrExportLimit means the account has downloaded its data too often today.
var ErrExportLimit = errors.New("too many data exports today")

// AccountExport is a copy of what one person gave or did. It leaves out other
// people, and reports and ratings about this person, so that using it cannot
// reveal who complained.
type AccountExport struct {
	GeneratedAt time.Time
	Truncated   bool
	Profile     ExportProfile
	Rides       []ExportRide
	Payments    []ExportPayment
	Documents   []ExportDocument
	Ratings     []ExportRating
	Reports     []ExportReport
	Messages    []ExportMessage
}

// ExportProfile is the account itself.
type ExportProfile struct {
	Phone, Email, DisplayName, PlateNumber *string
	AccountStatus                          string
	CreatedAt                              time.Time
	PhotoConsentAt                         *time.Time
}

// ExportRide is one trip, from this person's side.
type ExportRide struct {
	ID                       uuid.UUID
	Role, Status             string
	Pickup, Dropoff          geo.Point
	FareKES                  int32
	RequestedAt              time.Time
	CompletedAt, CancelledAt *time.Time
}

// ExportPayment is one subscription payment.
type ExportPayment struct {
	Channel, Status string
	AmountKES       int32
	RequestedAt     time.Time
	PaidAt          *time.Time
}

// ExportDocument describes an uploaded document, without its file.
type ExportDocument struct {
	DocumentType, Status string
	SubmittedAt          time.Time
	ReviewedAt           *time.Time
	ExpiresOn            *time.Time
}

// ExportRating is a rating this person gave.
type ExportRating struct {
	RideID      uuid.UUID
	Score       int32
	ReasonTags  []string
	Comment     *string
	SubmittedAt time.Time
}

// ExportReport is a report this person filed.
type ExportReport struct {
	Category, Status, Description string
	RideID                        *uuid.UUID
	CreatedAt                     time.Time
}

// ExportMessage is a chat message this person sent.
type ExportMessage struct {
	RideID    uuid.UUID
	Body      string
	CreatedAt time.Time
}

// ExportAccount returns the person's own data. A year of location history is
// valuable to a thief holding a stolen session, so it needs a recent sign-in,
// is limited, and is audited before anything is read.
func (s *Service) ExportAccount(ctx context.Context, p Principal, meta RequestMeta) (AccountExport, error) {
	now := s.now()
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "export:"+p.UserID.String()); err != nil {
			return fmt.Errorf("lock export: %w", err)
		}
		if err := requireFreshSignIn(ctx, q, p, now); err != nil {
			return err
		}
		done, err := q.CountAuditActionsSince(ctx, store.CountAuditActionsSinceParams{UserID: new(p.UserID), Action: exportAction, Since: now.Add(-24 * time.Hour)})
		if err != nil {
			return fmt.Errorf("count exports: %w", err)
		}
		if done >= exportsPerDay {
			return ErrExportLimit
		}
		return audit(ctx, q, auditEntry{action: exportAction, userID: new(p.UserID), family: new(p.FamilyID), meta: meta, at: now})
	})
	if err != nil {
		return AccountExport{}, err
	}
	out := AccountExport{GeneratedAt: now}
	profile, err := s.queries.GetExportProfile(ctx, p.UserID)
	if err != nil {
		return AccountExport{}, fmt.Errorf("load profile: %w", err)
	}
	out.Profile = ExportProfile{
		Phone: profile.Phone, Email: profile.Email, DisplayName: profile.DisplayName, PlateNumber: profile.PlateNumber,
		AccountStatus: profile.AccountStatus, CreatedAt: profile.CreatedAt, PhotoConsentAt: profile.PhotoConsentAt,
	}
	if err := s.loadExportTrips(ctx, p.UserID, &out); err != nil {
		return AccountExport{}, err
	}
	if err := s.loadExportActivity(ctx, p.UserID, &out); err != nil {
		return AccountExport{}, err
	}
	return out, nil
}

func (s *Service) loadExportTrips(ctx context.Context, id uuid.UUID, out *AccountExport) error {
	rides, err := s.queries.ListExportRides(ctx, store.ListExportRidesParams{ID: new(id), RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list rides: %w", err)
	}
	out.Rides = make([]ExportRide, len(rides))
	for i, r := range rides {
		out.Rides[i] = ExportRide{
			ID: r.ID, Role: r.Role, Status: r.Status, FareKES: r.FareKes, RequestedAt: r.RequestedAt,
			Pickup: geo.Point{Lat: r.PickupLat, Lng: r.PickupLng}, Dropoff: geo.Point{Lat: r.DropoffLat, Lng: r.DropoffLng},
			CompletedAt: r.CompletedAt, CancelledAt: r.CancelledAt,
		}
	}
	payments, err := s.queries.ListExportPayments(ctx, store.ListExportPaymentsParams{ID: id, RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list payments: %w", err)
	}
	out.Payments = make([]ExportPayment, len(payments))
	for i, p := range payments {
		out.Payments[i] = ExportPayment{Channel: p.Channel, Status: p.Status, AmountKES: p.AmountKes, RequestedAt: p.RequestedAt, PaidAt: p.PaidAt}
	}
	documents, err := s.queries.ListExportDocuments(ctx, store.ListExportDocumentsParams{ID: id, RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list documents: %w", err)
	}
	out.Documents = make([]ExportDocument, len(documents))
	for i, d := range documents {
		out.Documents[i] = ExportDocument{DocumentType: d.DocumentType, Status: d.Status, SubmittedAt: d.CreatedAt, ReviewedAt: d.ReviewedAt, ExpiresOn: d.ExpiresOn}
	}
	out.Truncated = out.Truncated || len(rides) == exportRowLimit || len(payments) == exportRowLimit || len(documents) == exportRowLimit
	return nil
}

func (s *Service) loadExportActivity(ctx context.Context, id uuid.UUID, out *AccountExport) error {
	ratings, err := s.queries.ListExportRatings(ctx, store.ListExportRatingsParams{ID: id, RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list ratings: %w", err)
	}
	out.Ratings = make([]ExportRating, len(ratings))
	for i, r := range ratings {
		out.Ratings[i] = ExportRating{RideID: r.RideID, Score: r.Score, ReasonTags: r.ReasonTags, Comment: r.Comment, SubmittedAt: r.SubmittedAt}
	}
	reports, err := s.queries.ListExportReports(ctx, store.ListExportReportsParams{ID: new(id), RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list reports: %w", err)
	}
	out.Reports = make([]ExportReport, len(reports))
	for i, r := range reports {
		out.Reports[i] = ExportReport{Category: r.Category, Status: r.Status, Description: r.Description, RideID: r.RideID, CreatedAt: r.CreatedAt}
	}
	messages, err := s.queries.ListExportMessages(ctx, store.ListExportMessagesParams{ID: id, RowLimit: exportRowLimit})
	if err != nil {
		return fmt.Errorf("list messages: %w", err)
	}
	out.Messages = make([]ExportMessage, len(messages))
	for i, m := range messages {
		out.Messages[i] = ExportMessage{RideID: m.RideID, Body: m.Body, CreatedAt: m.CreatedAt}
	}
	out.Truncated = out.Truncated || len(ratings) == exportRowLimit || len(reports) == exportRowLimit || len(messages) == exportRowLimit
	return nil
}
