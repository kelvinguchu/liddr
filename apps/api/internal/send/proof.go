package send

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	proofTTL       = 10 * time.Minute
	proofMaxBytes  = 10 << 20
	proofPerHour   = 30
	proofLinkTTL   = 5 * time.Minute
	kindPickup     = "pickup"
	kindDropoff    = "dropoff"
	statusArrived  = "arrived"
	statusUnderway = "in_progress"
)

var proofTypes = map[string]struct {
	extension string
	magic     string
}{
	"image/jpeg": {"jpg", "\xff\xd8\xff"},
	"image/png":  {"png", "\x89PNG\r\n\x1a\n"},
}

// ProofUpload is where to send a proof photo.
type ProofUpload struct {
	ID        uuid.UUID
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}

// loadForDriver confirms the delivery exists and belongs to this driver.
func (s *Service) loadForDriver(ctx context.Context, rideID, driverID uuid.UUID) (store.GetSendDeliveryRow, error) {
	row, err := s.queries.GetSendDelivery(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrNotFound
	}
	if err != nil {
		return row, fmt.Errorf("load delivery: %w", err)
	}
	if row.DriverID == nil || *row.DriverID != driverID {
		return row, ErrNotFound
	}
	return row, nil
}

// PrepareProof issues a signed URL for one proof photo on this driver's delivery.
func (s *Service) PrepareProof(ctx context.Context, rideID, driverID uuid.UUID, kind, contentType string, size int64) (ProofUpload, error) {
	if s.storage == nil {
		return ProofUpload{}, ErrUnavailable
	}
	format, ok := proofTypes[contentType]
	if !ok || (kind != kindPickup && kind != kindDropoff) || size <= 0 || size > proofMaxBytes {
		return ProofUpload{}, ErrInvalidProof
	}
	row, err := s.loadForDriver(ctx, rideID, driverID)
	if err != nil {
		return ProofUpload{}, err
	}
	if row.RideStatus != statusArrived && row.RideStatus != statusUnderway {
		return ProofUpload{}, ErrWrongState
	}
	now := s.now()
	random := make([]byte, 16)
	// crypto/rand.Read never returns an error; it aborts the program instead.
	_, _ = rand.Read(random)
	key := fmt.Sprintf("send/%s/%s/%s.%s", rideID, kind, hex.EncodeToString(random), format.extension)
	out := ProofUpload{ID: uuid.New(), ExpiresAt: now.Add(proofTTL)}
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := q.LockKey(ctx, "send:proof:"+driverID.String()); err != nil {
			return fmt.Errorf("lock driver: %w", err)
		}
		count, err := q.CountRecentSendProofUploads(ctx, store.CountRecentSendProofUploadsParams{DriverID: driverID, Since: now.Add(-time.Hour)})
		if err != nil {
			return fmt.Errorf("count uploads: %w", err)
		}
		if count >= proofPerHour {
			return ErrRateLimited
		}
		err = q.InsertSendProofUpload(ctx, store.InsertSendProofUploadParams{
			ID: out.ID, RideID: rideID, DriverID: driverID, ProofKind: kind, StorageKey: key,
			ContentType: contentType, SizeBytes: size, ExpiresAt: out.ExpiresAt, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert upload: %w", err)
		}
		return nil
	})
	if err != nil {
		return ProofUpload{}, err
	}
	signed, err := s.storage.SignUpload(key, contentType, size, proofTTL)
	if err != nil {
		return ProofUpload{}, fmt.Errorf("sign upload: %w", err)
	}
	out.URL, out.Headers = signed.URL, signed.Headers
	return out, nil
}

// checkUpload confirms the object exists and matches what was issued. It runs
// before any transaction, because it talks to storage.
func (s *Service) checkUpload(ctx context.Context, uploadID, rideID, driverID uuid.UUID, kind string) (store.GetSendProofUploadRow, error) {
	if s.storage == nil {
		return store.GetSendProofUploadRow{}, ErrUnavailable
	}
	upload, err := s.queries.GetSendProofUpload(ctx, store.GetSendProofUploadParams{ID: uploadID, DriverID: driverID})
	if errors.Is(err, pgx.ErrNoRows) {
		return upload, ErrNotFound
	}
	if err != nil {
		return upload, fmt.Errorf("load upload: %w", err)
	}
	if upload.RideID != rideID || upload.ProofKind != kind {
		return upload, ErrInvalidProof
	}
	if upload.ConsumedAt != nil || !s.now().Before(upload.ExpiresAt) {
		return upload, ErrUploadExpired
	}
	object, err := s.storage.Stat(ctx, upload.StorageKey)
	if err != nil {
		return upload, errors.Join(ErrUploadMissing, err)
	}
	if object.Size != upload.SizeBytes || object.ContentType != upload.ContentType {
		return upload, ErrUploadMissing
	}
	return upload, nil
}

func spend(ctx context.Context, q *store.Queries, uploadID uuid.UUID, now time.Time) error {
	consumed, err := q.ConsumeSendProofUpload(ctx, store.ConsumeSendProofUploadParams{Now: new(now), ID: uploadID})
	if err != nil {
		return fmt.Errorf("consume upload: %w", err)
	}
	if consumed == 0 {
		return ErrUploadExpired
	}
	return nil
}

// lockAssigned locks the ride and confirms this driver holds it in allowed status.
func lockAssigned(ctx context.Context, q *store.Queries, rideID, driverID uuid.UUID, allowed ...string) (store.GetRideDriverAndStatusRow, error) {
	ride, err := q.GetRideDriverAndStatus(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ride, ErrNotFound
	}
	if err != nil {
		return ride, fmt.Errorf("load ride: %w", err)
	}
	if ride.DriverID == nil || *ride.DriverID != driverID {
		return ride, ErrNotFound
	}
	if !slices.Contains(allowed, ride.Status) {
		return ride, ErrWrongState
	}
	return ride, nil
}
