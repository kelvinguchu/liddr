package messages

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/kelvinguchu/liddr/apps/api/internal/events"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

// lockMessage loads a message after confirming the user is on its ride.
func lockMessage(ctx context.Context, q *store.Queries, rideID, messageID, userID uuid.UUID) (store.GetRideMessageForUpdateRow, error) {
	if _, err := findParty(ctx, q, rideID, userID); err != nil {
		return store.GetRideMessageForUpdateRow{}, err
	}
	row, err := q.GetRideMessageForUpdate(ctx, store.GetRideMessageForUpdateParams{ID: messageID, RideID: rideID})
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrNotFound
	}
	if err != nil {
		return row, fmt.Errorf("load message: %w", err)
	}
	return row, nil
}

// MarkRead records that the recipient has read a message. It is safe to repeat.
func (s *Service) MarkRead(ctx context.Context, rideID, messageID, userID uuid.UUID) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := lockMessage(ctx, q, rideID, messageID, userID)
		if err != nil {
			return err
		}
		if row.RecipientID != userID {
			return ErrNotRecipient
		}
		if row.ReadAt != nil {
			return nil
		}
		if err := q.MarkRideMessageRead(ctx, store.MarkRideMessageReadParams{Now: new(now), ID: messageID}); err != nil {
			return fmt.Errorf("mark read: %w", err)
		}
		return events.Publish(ctx, q, events.Event{Type: events.TypeRideMessageRead, RideID: new(rideID)}, row.SenderID)
	})
}

// Hide removes a message from the user's own view only.
func (s *Service) Hide(ctx context.Context, rideID, messageID, userID uuid.UUID) error {
	now := s.now()
	return store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := lockMessage(ctx, q, rideID, messageID, userID)
		if err != nil {
			return err
		}
		return hide(ctx, q, row, userID, now)
	})
}

func hide(ctx context.Context, q *store.Queries, row store.GetRideMessageForUpdateRow, userID uuid.UUID, now time.Time) error {
	var err error
	if row.SenderID == userID {
		err = q.HideRideMessageForSender(ctx, store.HideRideMessageForSenderParams{Now: new(now), ID: row.ID})
	} else {
		err = q.HideRideMessageForRecipient(ctx, store.HideRideMessageForRecipientParams{Now: new(now), ID: row.ID})
	}
	if err != nil {
		return fmt.Errorf("hide message: %w", err)
	}
	return nil
}

// Report files a report about a message, hides it for the reporter, and
// restricts the sender if enough different people have reported them.
func (s *Service) Report(ctx context.Context, rideID, messageID, userID uuid.UUID, category string) (uuid.UUID, error) {
	if category == "" {
		category = defaultCategory
	}
	now := s.now()
	var reportID uuid.UUID
	err := store.InTx(ctx, s.pool, func(q *store.Queries) error {
		row, err := lockMessage(ctx, q, rideID, messageID, userID)
		if err != nil {
			return err
		}
		if row.SenderID == userID {
			return ErrOwnMessage
		}
		filed, err := s.moderation.SubmitInTx(ctx, q, moderation.Submission{
			ReporterID: userID, RideID: rideID, Category: category, Description: row.Body, MessageID: new(messageID),
		})
		if err != nil {
			return err
		}
		reportID = filed.ID
		if err := hide(ctx, q, row, userID, now); err != nil {
			return err
		}
		return s.escalate(ctx, q, row.SenderID, reportID, now)
	})
	if err != nil {
		return uuid.Nil, err
	}
	return reportID, nil
}

func (s *Service) escalate(ctx context.Context, q *store.Queries, sender, reportID uuid.UUID, now time.Time) error {
	reporters, err := q.CountMessageReporters(ctx, store.CountMessageReportersParams{ReportedID: sender, Since: now.Add(-reportWindow)})
	if err != nil {
		return fmt.Errorf("count reporters: %w", err)
	}
	if reporters < autoRestrictAt {
		return nil
	}
	restricted, err := q.HasCommunicationRestriction(ctx, store.HasCommunicationRestrictionParams{UserID: sender, Now: new(now)})
	if err != nil {
		return fmt.Errorf("check restriction: %w", err)
	}
	if restricted {
		return nil
	}
	_, err = s.moderation.ApplyInTx(ctx, q, moderation.Penalty{
		UserID: sender, ReportID: new(reportID), Action: "feature_restriction", Scope: moderation.ScopeCommunication,
		ReasonCode: "message_abuse_auto_restriction",
	})
	if err != nil {
		return fmt.Errorf("restrict sender: %w", err)
	}
	return s.moderation.RaiseSystemReport(ctx, q, moderation.SystemReport{
		ReportedID: sender, Category: defaultCategory, SignalKey: "message_abuse_signal", Severity: 4, IncidentType: "conduct",
		Description: "Messages restricted automatically after reports from several people.", Cooldown: signalCooldown,
	})
}
