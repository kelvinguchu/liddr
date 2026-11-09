package disputes

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	outcomeRefundFull    = "refund_full"
	outcomeRefundPartial = "refund_partial"
	outcomeCreditNote    = "credit_note"

	statusApproved  = "approved"
	statusPaid      = "paid"
	statusCancelled = "cancelled"
)

var channels = []string{"manual_ops", "mpesa_reversal", "wallet_credit", "bank_transfer"}

// Compensation is money owed because of a dispute.
type Compensation struct {
	ID            uuid.UUID
	ReportID      uuid.UUID
	RideID        uuid.UUID
	BeneficiaryID uuid.UUID
	Type          string
	Status        string
	AmountKES     int32
	Channel       *string
	Reference     *string
	ProcessedAt   *time.Time
	CreatedAt     time.Time
}

// Resolution is a staff ruling on a dispute.
type Resolution struct {
	Outcome   string
	AmountKES *int32
	Summary   *string
	Actor     uuid.UUID
}

func isCompensation(outcome string) bool {
	return outcome == outcomeRefundFull || outcome == outcomeRefundPartial || outcome == outcomeCreditNote
}

func decisionFor(outcome string) (string, error) {
	switch outcome {
	case "dismissed":
		return moderation.DecisionDismiss, nil
	case "escalate":
		return moderation.DecisionEscalate, nil
	case "no_action", outcomeRefundFull, outcomeRefundPartial, outcomeCreditNote:
		return moderation.DecisionNoAction, nil
	default:
		return "", ErrInvalidOutcome
	}
}

// amountDue caps every award at the fare the beneficiary was charged.
func amountDue(outcome string, requested *int32, fare int32) (int32, error) {
	if outcome == outcomeRefundFull {
		if fare <= 0 {
			return 0, ErrInvalidAmount
		}
		return fare, nil
	}
	if requested == nil || *requested <= 0 || *requested > fare {
		return 0, ErrInvalidAmount
	}
	return *requested, nil
}

// Resolve rules on a dispute and records any compensation, all or nothing.
func (s *Service) Resolve(ctx context.Context, id uuid.UUID, r Resolution) error {
	decision, err := decisionFor(r.Outcome)
	if err != nil {
		return err
	}
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		report, err := s.moderation.ReviewInTx(ctx, q, id, moderation.Decision{Decision: decision, Notes: r.Summary, Actor: r.Actor, Outcome: new(r.Outcome)})
		if err != nil {
			return translate(err)
		}
		if report.DisputeType == nil {
			return ErrNotFound
		}
		if !isCompensation(r.Outcome) {
			return nil
		}
		if report.RideID == nil || report.ReporterID == nil {
			return ErrNotRefundable
		}
		ride, err := q.GetRideParties(ctx, *report.RideID)
		if err != nil {
			return fmt.Errorf("load ride: %w", err)
		}
		// A driver was never charged a fare. On a shared trip each passenger has
		// their own, and their refund is capped at that.
		fare := ride.FareKes
		if *report.ReporterID != ride.RiderID {
			fare, err = q.GetSharedMemberFare(ctx, store.GetSharedMemberFareParams{RideID: ride.ID, RiderID: *report.ReporterID})
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotRefundable
			}
			if err != nil {
				return fmt.Errorf("load passenger fare: %w", err)
			}
		}
		amount, err := amountDue(r.Outcome, r.AmountKES, fare)
		if err != nil {
			return err
		}
		_, err = q.InsertCompensation(ctx, store.InsertCompensationParams{
			ID: uuid.New(), ReportID: id, RideID: ride.ID, BeneficiaryID: *report.ReporterID, CounterpartyID: new(report.ReportedID),
			ActorID: new(r.Actor), CompensationType: r.Outcome, AmountKes: amount, ReasonText: r.Summary, Now: now,
		})
		if err != nil {
			return fmt.Errorf("insert compensation: %w", err)
		}
		return nil
	})
}

func translate(err error) error {
	if errors.Is(err, moderation.ErrNotFound) {
		return ErrNotFound
	}
	return err
}

func toCompensation(id, report, ride, beneficiary uuid.UUID, kind, status string, amount int32, channel, reference *string, processed *time.Time, created time.Time) Compensation {
	return Compensation{ID: id, ReportID: report, RideID: ride, BeneficiaryID: beneficiary, Type: kind, Status: status, AmountKES: amount, Channel: channel, Reference: reference, ProcessedAt: processed, CreatedAt: created}
}

// Settlement records what happened to an approved compensation.
type Settlement struct {
	Channel   string
	Reference string
	Actor     uuid.UUID
}

// MarkPaid records that the money was sent. A reference is required, so every
// payout can be traced to a real transfer.
func (s *Service) MarkPaid(ctx context.Context, id uuid.UUID, in Settlement) (Compensation, error) {
	if !slices.Contains(channels, in.Channel) {
		return Compensation{}, ErrInvalidChannel
	}
	reference := strings.TrimSpace(in.Reference)
	if reference == "" || len(reference) > maxResolutionLen {
		return Compensation{}, ErrReferenceNeeded
	}
	return s.finish(ctx, id, statusPaid, new(in.Channel), new(reference), in.Actor)
}

// Cancel withdraws an approved compensation.
func (s *Service) Cancel(ctx context.Context, id, actor uuid.UUID) (Compensation, error) {
	return s.finish(ctx, id, statusCancelled, nil, nil, actor)
}

func (s *Service) finish(ctx context.Context, id uuid.UUID, status string, channel, reference *string, actor uuid.UUID) (Compensation, error) {
	now := s.now()
	var out Compensation
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := q.GetCompensationForUpdate(ctx, id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return fmt.Errorf("load compensation: %w", err)
		}
		if row.BeneficiaryID == actor {
			return ErrSelfAction
		}
		if row.Status != statusApproved {
			return ErrAlreadySettled
		}
		done, err := q.FinishCompensation(ctx, store.FinishCompensationParams{Status: status, Now: new(now), Actor: new(actor), Channel: channel, Reference: reference, ID: id})
		if err != nil {
			return fmt.Errorf("finish compensation: %w", err)
		}
		out = toCompensation(done.ID, done.ReportID, done.RideID, done.BeneficiaryID, done.CompensationType, done.Status, done.AmountKes, done.ProcessingChannel, done.ProcessingReference, done.ProcessedAt, done.CreatedAt)
		return nil
	})
	return out, err
}

// ListForUser returns compensation owed to a user.
func (s *Service) ListForUser(ctx context.Context, userID uuid.UUID, limit, offset int32) ([]Compensation, error) {
	rows, err := s.queries.ListCompensationsForUser(ctx, store.ListCompensationsForUserParams{UserID: userID, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list compensations: %w", err)
	}
	out := make([]Compensation, len(rows))
	for i, r := range rows {
		out[i] = toCompensation(r.ID, r.ReportID, r.RideID, r.BeneficiaryID, r.CompensationType, r.Status, r.AmountKes, r.ProcessingChannel, r.ProcessingReference, r.ProcessedAt, r.CreatedAt)
	}
	return out, nil
}

// ListForOps returns compensation in one status.
func (s *Service) ListForOps(ctx context.Context, status string, limit, offset int32) ([]Compensation, error) {
	rows, err := s.queries.ListCompensationsForOps(ctx, store.ListCompensationsForOpsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list compensations: %w", err)
	}
	out := make([]Compensation, len(rows))
	for i, r := range rows {
		out[i] = toCompensation(r.ID, r.ReportID, r.RideID, r.BeneficiaryID, r.CompensationType, r.Status, r.AmountKes, r.ProcessingChannel, r.ProcessingReference, r.ProcessedAt, r.CreatedAt)
	}
	return out, nil
}

// OpsCase is a dispute with everything a reviewer needs.
type OpsCase struct {
	ID                  uuid.UUID
	ReporterID          *uuid.UUID
	ReportedID          uuid.UUID
	RideID              *uuid.UUID
	Type                string
	Status              string
	Severity            int32
	IncidentType        string
	RequestedResolution *string
	Description         string
	CreatedAt           time.Time
}

// ListCases returns disputes in one status, most severe first.
func (s *Service) ListCases(ctx context.Context, status string, limit, offset int32) ([]OpsCase, error) {
	rows, err := s.queries.ListDisputesForOps(ctx, store.ListDisputesForOpsParams{Status: status, RowLimit: limit, RowOffset: offset})
	if err != nil {
		return nil, fmt.Errorf("list disputes: %w", err)
	}
	out := make([]OpsCase, len(rows))
	for i, r := range rows {
		kind := ""
		if r.DisputeType != nil {
			kind = *r.DisputeType
		}
		out[i] = OpsCase{ID: r.ID, ReporterID: r.ReporterID, ReportedID: r.ReportedID, RideID: r.RideID, Type: kind, Status: r.Status, Severity: r.Severity, IncidentType: r.IncidentType, RequestedResolution: r.RequestedResolution, Description: r.Description, CreatedAt: r.CreatedAt}
	}
	return out, nil
}
