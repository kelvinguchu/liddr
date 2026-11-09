package verification

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

var platePattern = regexp.MustCompile(`^K[A-Z]{2,3}[0-9]{3}[A-Z]?$`)

// Application is a driver's verification attempt.
type Application struct {
	ID             uuid.UUID
	Status         string
	DecidedAt      *time.Time
	DecisionReason *string
	CreatedAt      time.Time
}

// NormalizePlate returns a plate in its stored form, such as KMFB123A.
func NormalizePlate(raw string) (string, error) {
	plate := strings.ToUpper(strings.NewReplacer(" ", "", "-", "").Replace(raw))
	if !platePattern.MatchString(plate) {
		return "", ErrInvalidPlate
	}
	return plate, nil
}

// StartApplication opens an application, or returns the one already open.
func (s *Service) StartApplication(ctx context.Context, driverID uuid.UUID, rawPlate string) (Application, error) {
	plate, err := NormalizePlate(rawPlate)
	if err != nil {
		return Application{}, err
	}
	now := s.now()
	var out Application
	err = store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, driverID); err != nil {
			return err
		}
		if err := s.loadDriver(ctx, q, driverID); err != nil {
			return err
		}
		open, err := q.GetOpenApplication(ctx, driverID)
		if err == nil {
			out = Application{ID: open.ID, Status: open.Status, CreatedAt: open.CreatedAt}
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("load open application: %w", err)
		}
		latest, err := q.GetLatestApplication(ctx, driverID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("load latest application: %w", err)
		}
		// Only operations can lift their own suspension. A lapsed document also
		// suspends a driver, but leaves the application as it was.
		if err == nil && latest.Status == statusSuspended {
			return ErrApplicationBlocked
		}
		if err := q.SetDriverPlate(ctx, store.SetDriverPlateParams{PlateNumber: new(plate), Now: now, UserID: driverID}); err != nil {
			return fmt.Errorf("set plate: %w", err)
		}
		row, err := q.InsertApplication(ctx, store.InsertApplicationParams{ID: uuid.New(), DriverID: driverID, Now: now})
		if err != nil {
			return fmt.Errorf("insert application: %w", err)
		}
		out = Application{ID: row.ID, Status: row.Status, CreatedAt: row.CreatedAt}
		return nil
	})
	if err != nil {
		return Application{}, err
	}
	return out, nil
}

func (s *Service) loadDriver(ctx context.Context, q *store.Queries, driverID uuid.UUID) error {
	_, err := q.GetVerificationDriver(ctx, driverID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrProfileMissing
	}
	if err != nil {
		return fmt.Errorf("load driver: %w", err)
	}
	return nil
}

// UploadRequest describes the file a driver is about to upload.
type UploadRequest struct {
	DriverID     uuid.UUID
	DocumentType string
	ContentType  string
	SizeBytes    int64
}

// Upload is where and how to send the file.
type Upload struct {
	ID        uuid.UUID
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}

// PrepareUpload issues a signed URL for one specific document. The server picks
// the storage key at random, so a client can never name another driver's file.
func (s *Service) PrepareUpload(ctx context.Context, req UploadRequest) (Upload, error) {
	if s.storage == nil || s.scanner == nil {
		return Upload{}, ErrUnavailable
	}
	kind, ok := allowedTypes[req.ContentType]
	if !ok || req.SizeBytes <= 0 || req.SizeBytes > maxFileBytes {
		return Upload{}, ErrInvalidFile
	}
	now := s.now()
	random := make([]byte, 16)
	// crypto/rand.Read never returns an error; it aborts the program instead.
	_, _ = rand.Read(random)
	key := fmt.Sprintf("verification/%s/%s.%s", req.DriverID, hex.EncodeToString(random), kind.extension)
	out := Upload{ID: uuid.New(), ExpiresAt: now.Add(uploadTTL)}

	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		if err := lockDriver(ctx, q, req.DriverID); err != nil {
			return err
		}
		if err := s.loadDriver(ctx, q, req.DriverID); err != nil {
			return err
		}
		if _, err := q.GetVerificationRequirement(ctx, req.DocumentType); errors.Is(err, pgx.ErrNoRows) {
			return ErrInvalidDocument
		} else if err != nil {
			return fmt.Errorf("load requirement: %w", err)
		}
		count, err := q.CountRecentUploads(ctx, store.CountRecentUploadsParams{DriverID: req.DriverID, Since: now.Add(-time.Hour)})
		if err != nil {
			return fmt.Errorf("count uploads: %w", err)
		}
		if count >= uploadsPerHour {
			return ErrRateLimited
		}
		err = q.InsertUpload(ctx, store.InsertUploadParams{
			ID: out.ID, DriverID: req.DriverID, DocumentType: req.DocumentType, StorageKey: key,
			ContentType: req.ContentType, SizeBytes: req.SizeBytes, ExpiresAt: out.ExpiresAt, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert upload: %w", err)
		}
		return nil
	})
	if err != nil {
		return Upload{}, err
	}
	signed, err := s.storage.SignUpload(key, req.ContentType, req.SizeBytes, uploadTTL)
	if err != nil {
		return Upload{}, fmt.Errorf("sign upload: %w", err)
	}
	out.URL, out.Headers = signed.URL, signed.Headers
	return out, nil
}
