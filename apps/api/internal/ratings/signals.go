package ratings

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const (
	categoryQuality      = "rating_quality_risk"
	categoryManipulation = "rating_manipulation_risk"

	velocityWindow    = time.Hour
	velocityThreshold = 10
	pairWindow        = 30 * 24 * time.Hour
	pairMinimum       = 5
	pairRatioPercent  = 70
)

type lowRule struct {
	code     string
	belowC   int32
	minCount int32
	severity int32
}

// Rules are checked most severe first.
var (
	driverRules = []lowRule{
		{"driver_critical_3_0_over_20", 300, 20, 5},
		{"driver_low_3_5_over_50", 350, 50, 4},
		{"driver_low_3_7_over_30", 370, 30, 3},
	}
	riderRules = []lowRule{{"rider_low_3_5_over_30", 350, 30, 2}}
)

func (s *Service) checkLowRating(ctx context.Context, q *store.Queries, user uuid.UUID, centi *int32, count int32, now time.Time) error {
	if centi == nil {
		return nil
	}
	recent, err := q.GetRatingGuardrail(ctx, store.GetRatingGuardrailParams{RatedUser: user, Since: now.Add(-guardrailWindow)})
	if err != nil {
		return fmt.Errorf("load guardrail: %w", err)
	}
	if recent < guardrailMinimum {
		return nil
	}
	roles, err := q.GetUserRoles(ctx, user)
	if err != nil {
		return fmt.Errorf("load roles: %w", err)
	}
	rules := riderRules
	if slices.Contains(roles, "driver") {
		rules = driverRules
	}
	for _, rule := range rules {
		if *centi < rule.belowC && count >= rule.minCount {
			return s.moderation.RaiseSystemReport(ctx, q, moderation.SystemReport{
				ReportedID: user, Category: categoryQuality, SignalKey: "rating_signal:" + rule.code,
				Severity: rule.severity, IncidentType: "conduct",
				Description: fmt.Sprintf("Rating %d.%02d across %d rated rides needs review (%s).", *centi/100, *centi%100, count, rule.code),
				Cooldown:    7 * 24 * time.Hour,
			})
		}
	}
	return nil
}

func (s *Service) checkManipulation(ctx context.Context, q *store.Queries, user, rater uuid.UUID, now time.Time) error {
	fast, err := q.CountFiveStarsSince(ctx, store.CountFiveStarsSinceParams{RatedUser: user, Since: now.Add(-velocityWindow)})
	if err != nil {
		return fmt.Errorf("count recent ratings: %w", err)
	}
	if fast >= velocityThreshold {
		err := s.moderation.RaiseSystemReport(ctx, q, moderation.SystemReport{
			ReportedID: user, Category: categoryManipulation, SignalKey: "rating_abuse:five_star_velocity_1h",
			Severity: 3, IncidentType: "fraud", Cooldown: 3 * 24 * time.Hour,
			Description: fmt.Sprintf("%d five-star ratings within one hour.", fast),
		})
		if err != nil {
			return err
		}
	}
	since := now.Add(-pairWindow)
	pair, err := q.CountFiveStarsFromRater(ctx, store.CountFiveStarsFromRaterParams{RatedUser: user, RatedBy: rater, Since: since})
	if err != nil {
		return fmt.Errorf("count pair ratings: %w", err)
	}
	total, err := q.GetRatingGuardrail(ctx, store.GetRatingGuardrailParams{RatedUser: user, Since: since})
	if err != nil {
		return fmt.Errorf("count ratings: %w", err)
	}
	if pair < pairMinimum || total < pairMinimum || pair*100 < total*pairRatioPercent {
		return nil
	}
	return s.moderation.RaiseSystemReport(ctx, q, moderation.SystemReport{
		ReportedID: user, Category: categoryManipulation, SignalKey: "rating_abuse:pair_30d:" + rater.String(),
		Severity: 3, IncidentType: "fraud", Cooldown: 7 * 24 * time.Hour,
		Description: fmt.Sprintf("One rater gave %d of %d ratings in 30 days, all five stars.", pair, total),
	})
}
