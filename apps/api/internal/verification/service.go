// Package verification takes a driver from uploaded documents to approval.
package verification

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/netip"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/malware"
	"github.com/kelvinguchu/liddr/apps/api/internal/storage"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	uploadTTL      = 10 * time.Minute
	downloadTTL    = 5 * time.Minute
	maxFileBytes   = 10 << 20
	uploadsPerHour = 60

	statusPending     = "pending"
	statusUnderReview = "under_review"
	statusApproved    = "approved"
	statusRejected    = "rejected"
	statusResubmit    = "resubmission_required"
	statusSuspended   = "suspended"

	docScanning      = "scanning"
	docPendingReview = "pending_review"
	docValidated     = "validated"
	docExpired       = "expired"

	scanPending  = "pending"
	scanClean    = "clean"
	scanInfected = "infected"
	scanFailed   = "failed"
)

// Errors returned to callers.
var (
	ErrUnavailable          = errors.New("document storage is not configured")
	ErrProfileMissing       = errors.New("driver profile does not exist")
	ErrInvalidPlate         = errors.New("plate number is not valid")
	ErrPhotoConsentRequired = errors.New("photo consent is required")
	ErrApplicationBlocked   = errors.New("driver has been suspended by operations")
	ErrNoOpenApplication    = errors.New("no application is open")
	ErrApplicationClosed    = errors.New("application cannot be reviewed")
	ErrNotFound             = errors.New("not found")
	ErrInvalidDocument      = errors.New("document type is not required")
	ErrInvalidFile          = errors.New("file type or size is not allowed")
	ErrExpiryRequired       = errors.New("document needs a future expiry date")
	ErrUploadExpired        = errors.New("upload is no longer valid")
	ErrUploadMissing        = errors.New("uploaded file was not found or does not match")
	ErrRateLimited          = errors.New("too many uploads")
	ErrInvalidDecision      = errors.New("decision is not valid")
	ErrReasonRequired       = errors.New("a reason is required")
	ErrSelfReview           = errors.New("staff cannot review their own documents")
	ErrDocumentNotReady     = errors.New("document cannot be reviewed")
	ErrDocumentsMissing     = errors.New("not every required document is validated")
)

// allowedTypes maps each accepted content type to its extension and file signature.
var allowedTypes = map[string]struct {
	extension string
	magic     string
}{
	"image/jpeg":      {"jpg", "\xff\xd8\xff"},
	"image/png":       {"png", "\x89PNG\r\n\x1a\n"},
	"application/pdf": {"pdf", "%PDF-"},
}

// Config holds the dependencies of a Service. Storage and Scanner are nil when
// the deployment has no document storage, and every upload then fails.
type Config struct {
	Pool    *pgxpool.Pool
	Storage *storage.Client
	Scanner *malware.Client
	Now     func() time.Time
	Logger  *slog.Logger
}

// Service implements driver verification.
type Service struct {
	pool    *pgxpool.Pool
	queries *store.Queries
	storage *storage.Client
	scanner *malware.Client
	now     func() time.Time
	logger  *slog.Logger
}

// NewService returns a Service using cfg.
func NewService(cfg Config) *Service {
	return &Service{
		pool:    cfg.Pool,
		queries: store.New(cfg.Pool),
		storage: cfg.Storage,
		scanner: cfg.Scanner,
		now:     cfg.Now,
		logger:  cfg.Logger,
	}
}

var nairobi = time.FixedZone("EAT", 3*60*60)

// today is the current Nairobi date, in the midnight-UTC form dates use here.
func (s *Service) today() time.Time {
	y, m, d := s.now().In(nairobi).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// lockDriver serializes every change to one driver's verification. Applicant
// and reviewer paths both begin here, so they can never deadlock on row order.
func lockDriver(ctx context.Context, q *store.Queries, driverID uuid.UUID) error {
	if err := q.LockKey(ctx, "verification:driver:"+driverID.String()); err != nil {
		return fmt.Errorf("lock driver: %w", err)
	}
	return nil
}

// Actor identifies the staff member behind a decision, for the audit trail.
type Actor struct {
	UserID    uuid.UUID
	RequestID string
	IP        netip.Addr
}

type reviewEntry struct {
	applicationID uuid.UUID
	documentID    *uuid.UUID
	driverID      uuid.UUID
	reviewerID    *uuid.UUID
	decision      string
	before, after string
	reason        *string
	at            time.Time
}

func recordReview(ctx context.Context, q *store.Queries, e reviewEntry) error {
	err := q.InsertVerificationReview(ctx, store.InsertVerificationReviewParams{
		ApplicationID: e.applicationID,
		DocumentID:    e.documentID,
		DriverID:      e.driverID,
		ReviewerID:    e.reviewerID,
		Decision:      e.decision,
		StatusBefore:  e.before,
		StatusAfter:   e.after,
		Reason:        e.reason,
		Now:           e.at,
	})
	if err != nil {
		return fmt.Errorf("record review: %w", err)
	}
	return nil
}

func notify(ctx context.Context, q *store.Queries, driverID uuid.UUID, status string) error {
	return events.Notify(ctx, q, events.Event{Type: events.TypeVerificationUpdated, Status: status}, driverID)
}
