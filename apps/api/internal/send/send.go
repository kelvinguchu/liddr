// Package send handles package delivery on top of the ride lifecycle.
package send

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/malware"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	maxNameLen = 100
	maxItemLen = 500
	maxNoteLen = 500

	sizeSmall  = "small"
	sizeMedium = "medium"
	sizeLarge  = "large"
)

// Errors returned to callers.
var (
	ErrUnavailable      = errors.New("delivery proof storage is not configured")
	ErrInvalidDetails   = errors.New("delivery details are not valid")
	ErrInvalidPhone     = errors.New("recipient phone is not valid")
	ErrInvalidPayment   = errors.New("recipient cannot pay before delivery")
	ErrAckRequired      = errors.New("liability must be acknowledged")
	ErrNotFound         = errors.New("delivery not found")
	ErrInvalidProof     = errors.New("proof type or file is not allowed")
	ErrWrongState       = errors.New("not possible at this stage of the delivery")
	ErrUploadExpired    = errors.New("upload is no longer valid")
	ErrUploadMissing    = errors.New("uploaded file was not found or does not match")
	ErrNotRecipient     = errors.New("account is not the recipient")
	ErrPickupProofFirst = errors.New("pickup proof is required first")
	ErrAlreadyConfirmed = errors.New("recipient already confirmed")
	ErrRateLimited      = errors.New("too many uploads")
	ErrPhoneRequired    = errors.New("sender has no verified phone")
)

// BlockedError reports an item that cannot be sent.
type BlockedError struct {
	Messages []string
}

func (e *BlockedError) Error() string { return "item cannot be sent" }

// Config holds the dependencies of a Service.
type Config struct {
	Pool    *pgxpool.Pool
	Rides   *rides.Service
	Storage *storage.Client
	Scanner *malware.Client
	Now     func() time.Time
}

// Service implements Send.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	rides   *rides.Service
	storage *storage.Client
	scanner *malware.Client
	now     func() time.Time
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{pool: cfg.Pool, queries: store.New(cfg.Pool), rides: cfg.Rides, storage: cfg.Storage, scanner: cfg.Scanner, now: cfg.Now}
}

var nonWord = regexp.MustCompile(`[^a-z0-9]+`)

func normalizeWords(text string) string {
	return " " + strings.TrimSpace(nonWord.ReplaceAllString(strings.ToLower(text), " ")) + " "
}

// mentions matches whole words and simple plurals, so that "cash" stops a
// parcel of banknotes and does not stop a bag of cashew nuts.
func mentions(words, keyword string) bool {
	k := strings.TrimSpace(normalizeWords(keyword))
	return strings.Contains(words, " "+k+" ") || strings.Contains(words, " "+k+"s ")
}

// Screening is the outcome of checking an item description.
type Screening struct {
	Warnings []string
}

func (s *Service) screen(ctx context.Context, q *store.Queries, description string) (Screening, error) {
	items, err := q.ListActiveProhibitedItems(ctx)
	if err != nil {
		return Screening{}, fmt.Errorf("list prohibited items: %w", err)
	}
	words := normalizeWords(description)
	var out Screening
	var blocked []string
	for _, item := range items {
		if !mentions(words, item.Keyword) {
			continue
		}
		if item.Severity == "block" {
			blocked = append(blocked, item.Message)
		} else {
			out.Warnings = append(out.Warnings, item.Message)
		}
	}
	if len(blocked) > 0 {
		return Screening{}, &BlockedError{Messages: blocked}
	}
	return out, nil
}

// Request books a delivery.
type Request struct {
	SenderID      uuid.UUID
	SenderPhone   string
	QuoteID       uuid.UUID
	SenderName    string
	RecipientName string
	RecipientRaw  string
	Item          string
	Size          string
	Payer         string
	Timing        string
	ItemValueKES  *int32
	Instructions  *string
	Acknowledged  bool
}

func (r Request) validate() error {
	sender, recipient, item := strings.TrimSpace(r.SenderName), strings.TrimSpace(r.RecipientName), strings.TrimSpace(r.Item)
	if sender == "" || len(sender) > maxNameLen || recipient == "" || len(recipient) > maxNameLen || item == "" || len(item) > maxItemLen {
		return ErrInvalidDetails
	}
	if r.Size != sizeSmall && r.Size != sizeMedium && r.Size != sizeLarge {
		return ErrInvalidDetails
	}
	if (r.Payer != "sender" && r.Payer != "recipient") || (r.Timing != "before" && r.Timing != "after") {
		return ErrInvalidDetails
	}
	if r.Payer == "recipient" && r.Timing == "before" {
		return ErrInvalidPayment
	}
	if r.ItemValueKES != nil && *r.ItemValueKES < 0 {
		return ErrInvalidDetails
	}
	if r.Instructions != nil && len(*r.Instructions) > maxNoteLen {
		return ErrInvalidDetails
	}
	return nil
}

// Book screens the item and creates the ride and delivery together. Whether the
// recipient has an account is deliberately not checked here: that answer would
// let anyone test which phone numbers are registered.
func (s *Service) Book(ctx context.Context, r Request) (rides.Ride, error) {
	if err := r.validate(); err != nil {
		return rides.Ride{}, err
	}
	if r.SenderPhone == "" {
		return rides.Ride{}, ErrPhoneRequired
	}
	recipient, err := auth.NormalizePhone(r.RecipientRaw)
	if err != nil {
		return rides.Ride{}, ErrInvalidPhone
	}
	screening, err := s.screen(ctx, s.queries, r.Item)
	if err != nil {
		return rides.Ride{}, err
	}
	if len(screening.Warnings) > 0 && !r.Acknowledged {
		return rides.Ride{}, ErrAckRequired
	}
	return s.rides.BookDelivery(ctx, r.SenderID, r.QuoteID, func(ctx context.Context, q *store.Queries, rideID uuid.UUID, now time.Time) error {
		err := q.InsertSendDelivery(ctx, store.InsertSendDeliveryParams{
			RideID: rideID, SenderName: strings.TrimSpace(r.SenderName), SenderPhone: r.SenderPhone,
			RecipientName: strings.TrimSpace(r.RecipientName), RecipientPhone: recipient, ItemDescription: strings.TrimSpace(r.Item),
			ItemSize: r.Size, Payer: r.Payer, PaymentTiming: r.Timing, ItemValueKes: r.ItemValueKES,
			SpecialInstructions: r.Instructions, LiabilityAcknowledged: r.Acknowledged, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert delivery: %w", err)
		}
		return nil
	})
}

// View is a delivery as one of its parties sees it. Phone numbers are shown
// only to the driver who is carrying the package.
type View struct {
	RideID         uuid.UUID
	SenderName     string
	RecipientName  string
	RecipientPhone *string
	Item           string
	Size           string
	Payer          string
	Timing         string
	Instructions   *string
	Status         string
	PickupProofAt  *time.Time
	DropoffProofAt *time.Time
	ConfirmedAt    *time.Time
}

// Get returns a delivery to its sender, driver or recipient.
func (s *Service) Get(ctx context.Context, rideID, userID uuid.UUID, phone string) (View, error) {
	row, err := s.queries.GetSendDelivery(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return View{}, ErrNotFound
	}
	if err != nil {
		return View{}, fmt.Errorf("load delivery: %w", err)
	}
	isDriver := row.DriverID != nil && *row.DriverID == userID
	if row.RiderID != userID && !isDriver && (phone == "" || row.RecipientPhone != phone) {
		return View{}, ErrNotFound
	}
	out := View{
		RideID: row.RideID, SenderName: row.SenderName, RecipientName: row.RecipientName, Item: row.ItemDescription, Size: row.ItemSize,
		Payer: row.Payer, Timing: row.PaymentTiming, Instructions: row.SpecialInstructions, Status: row.DeliveryStatus,
		PickupProofAt: row.PickupProofAt, DropoffProofAt: row.DropoffProofAt, ConfirmedAt: row.RecipientConfirmedAt,
	}
	if isDriver {
		out.RecipientPhone = new(row.RecipientPhone)
	}
	return out, nil
}
