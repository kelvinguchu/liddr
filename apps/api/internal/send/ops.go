package send

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// ProofAuditor records who viewed a proof.
type ProofAuditor func(ctx context.Context, q *store.Queries, key string, now time.Time) error

// ProofLink returns a five-minute link to a proof photo for staff settling a
// dispute. The file is checked first, because it came from a driver's phone.
func (s *Service) ProofLink(ctx context.Context, rideID uuid.UUID, kind string, audit ProofAuditor) (string, time.Time, error) {
	if s.storage == nil || s.scanner == nil {
		return "", time.Time{}, ErrUnavailable
	}
	row, err := s.queries.GetSendDelivery(ctx, rideID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", time.Time{}, ErrNotFound
	}
	if err != nil {
		return "", time.Time{}, fmt.Errorf("load delivery: %w", err)
	}
	key := row.PickupProofKey
	if kind == kindDropoff {
		key = row.DropoffProofKey
	}
	if key == nil {
		return "", time.Time{}, ErrNotFound
	}
	data, err := s.storage.Read(ctx, *key, proofMaxBytes)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("read proof: %w", err)
	}
	safeType := false
	for _, format := range proofTypes {
		safeType = safeType || strings.HasPrefix(string(data), format.magic)
	}
	verdict, err := s.scanner.Scan(ctx, data)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("scan proof: %w", err)
	}
	if !safeType || !verdict.Clean {
		return "", time.Time{}, ErrInvalidProof
	}
	link, err := s.storage.SignDownload(*key, proofLinkTTL)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("sign download: %w", err)
	}
	now := s.now()
	if err := audit(ctx, s.queries, *key, now); err != nil {
		return "", time.Time{}, err
	}
	return link, now.Add(proofLinkTTL), nil
}

// ProhibitedItem is one screening rule.
type ProhibitedItem struct {
	Keyword, Severity, Message string
	Active                     bool
}

// ListProhibited returns every screening rule.
func (s *Service) ListProhibited(ctx context.Context) ([]ProhibitedItem, error) {
	rows, err := s.queries.ListProhibitedItems(ctx)
	if err != nil {
		return nil, fmt.Errorf("list items: %w", err)
	}
	out := make([]ProhibitedItem, len(rows))
	for i, r := range rows {
		out[i] = ProhibitedItem{Keyword: r.Keyword, Severity: r.Severity, Message: r.Message, Active: r.Active}
	}
	return out, nil
}

// SaveProhibited adds or changes a screening rule.
func (s *Service) SaveProhibited(ctx context.Context, item ProhibitedItem) error {
	keyword := strings.ToLower(strings.TrimSpace(item.Keyword))
	if len(keyword) < 2 || len(keyword) > maxNameLen || strings.TrimSpace(item.Message) == "" || (item.Severity != "block" && item.Severity != "warn") {
		return ErrInvalidDetails
	}
	err := s.queries.UpsertProhibitedItem(ctx, store.UpsertProhibitedItemParams{Keyword: keyword, Severity: item.Severity, Message: strings.TrimSpace(item.Message), Active: item.Active, Now: s.now()})
	if err != nil {
		return fmt.Errorf("save item: %w", err)
	}
	return nil
}
