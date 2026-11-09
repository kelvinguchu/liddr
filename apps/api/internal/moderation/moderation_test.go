package moderation_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type world struct {
	pool    *pgxpool.Pool
	service *moderation.Service
	seed    *testdb.Seeder
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	w.seed = &testdb.Seeder{Pool: w.pool}
	w.service = moderation.NewService(moderation.Config{Pool: w.pool, Now: func() time.Time { return w.now }})
	return w
}

func (w *world) status(t *testing.T, user uuid.UUID) string {
	t.Helper()
	var status string
	if err := w.pool.QueryRow(t.Context(), `SELECT account_status FROM users WHERE id = $1`, user).Scan(&status); err != nil {
		t.Fatalf("read status: %v", err)
	}
	return status
}

func (w *world) penalize(t *testing.T, user, actor uuid.UUID, action string, ends *time.Time) moderation.Enforcement {
	t.Helper()
	out, err := w.service.Apply(t.Context(), moderation.Penalty{UserID: user, Actor: actor, Action: action, ReasonCode: "test", EndsAt: ends})
	if err != nil {
		t.Fatalf("Apply(%s): %v", action, err)
	}
	return out
}

func TestWarningNeverLiftsAHeavierPenalty(t *testing.T) {
	cases := []struct {
		name  string
		first string
		want  string
	}{
		{"ban survives a warning", "permanent_ban", "banned"},
		{"suspension survives a warning", "temporary_suspension", "suspended"},
		{"restriction survives a warning", "feature_restriction", "restricted"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			user, staff := w.seed.User(t, "rider"), w.seed.User(t, "ops")
			var ends *time.Time
			if tc.first == "temporary_suspension" {
				ends = new(w.now.Add(24 * time.Hour))
			}
			w.penalize(t, user, staff, tc.first, ends)
			w.penalize(t, user, staff, "warning", nil)
			if got := w.status(t, user); got != tc.want {
				t.Errorf("status = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestLiftingOnePenaltyKeepsTheOthers(t *testing.T) {
	w := newWorld(t)
	user, staff := w.seed.User(t, "rider"), w.seed.User(t, "ops")
	suspension := w.penalize(t, user, staff, "temporary_suspension", new(w.now.Add(time.Hour)))
	ban := w.penalize(t, user, staff, "permanent_ban", nil)
	if err := w.service.Lift(t.Context(), suspension.ID, staff); err != nil {
		t.Fatalf("Lift: %v", err)
	}
	if got := w.status(t, user); got != "banned" {
		t.Errorf("after lifting the suspension = %s, want banned", got)
	}
	if err := w.service.Lift(t.Context(), ban.ID, staff); err != nil {
		t.Fatalf("Lift: %v", err)
	}
	if got := w.status(t, user); got != "active" {
		t.Errorf("after lifting everything = %s, want active", got)
	}
	if err := w.service.Lift(t.Context(), ban.ID, staff); !errors.Is(err, moderation.ErrEnforcementClosed) {
		t.Errorf("lifting twice = %v", err)
	}
}

func TestSuspensionExpiresOnTime(t *testing.T) {
	w := newWorld(t)
	user, staff := w.seed.User(t, "rider"), w.seed.User(t, "ops")
	w.penalize(t, user, staff, "temporary_suspension", new(w.now.Add(time.Hour)))
	if err := w.service.ExpireDue(t.Context()); err != nil {
		t.Fatalf("ExpireDue: %v", err)
	}
	if got := w.status(t, user); got != "suspended" {
		t.Fatalf("before the end = %s", got)
	}
	w.now = w.now.Add(time.Hour)
	if err := w.service.ExpireDue(t.Context()); err != nil {
		t.Fatalf("ExpireDue: %v", err)
	}
	if got := w.status(t, user); got != "active" {
		t.Errorf("after the end = %s", got)
	}
}

func TestDriverIsTakenOfflineWhenSuspended(t *testing.T) {
	w := newWorld(t)
	driver, staff := w.seed.User(t, "driver"), w.seed.User(t, "ops")
	if _, err := w.pool.Exec(t.Context(), `UPDATE drivers SET is_online = true WHERE user_id = $1`, driver); err != nil {
		t.Fatalf("set online: %v", err)
	}
	w.penalize(t, driver, staff, "permanent_ban", nil)
	var online bool
	if err := w.pool.QueryRow(t.Context(), `SELECT is_online FROM drivers WHERE user_id = $1`, driver).Scan(&online); err != nil || online {
		t.Errorf("online = %v, %v", online, err)
	}
}

func TestSuspensionEndIsBounded(t *testing.T) {
	w := newWorld(t)
	user, staff := w.seed.User(t, "rider"), w.seed.User(t, "ops")
	for name, ends := range map[string]*time.Time{"missing": nil, "past": new(w.now.Add(-time.Hour)), "too far": new(w.now.AddDate(2, 0, 0))} {
		t.Run(name, func(t *testing.T) {
			_, err := w.service.Apply(t.Context(), moderation.Penalty{UserID: user, Actor: staff, Action: "temporary_suspension", ReasonCode: "t", EndsAt: ends})
			if !errors.Is(err, moderation.ErrInvalidEnd) {
				t.Errorf("Apply = %v", err)
			}
		})
	}
}

func (w *world) finishedRide(t *testing.T) (ride, rider, driver uuid.UUID) {
	t.Helper()
	rider, driver = w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride = w.seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: "completed", FareKES: 300, Ended: w.now})
	return ride, rider, driver
}

func TestReportsAreAimedByTheServer(t *testing.T) {
	w := newWorld(t)
	ride, rider, driver := w.finishedRide(t)
	sub := moderation.Submission{ReporterID: rider, RideID: ride, Category: "unsafe_driving", Description: "too fast"}
	first, err := w.service.Submit(t.Context(), sub)
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	report, err := w.service.GetReport(t.Context(), first.ID)
	if err != nil || report.ReportedID != driver {
		t.Fatalf("report = %+v, %v", report, err)
	}
	again, err := w.service.Submit(t.Context(), sub)
	if err != nil || again.ID != first.ID {
		t.Errorf("repeat = %+v, %v, want the original", again, err)
	}

	stranger := w.seed.User(t, "rider")
	cases := []struct {
		name string
		sub  moderation.Submission
		want error
	}{
		{"not on the ride", moderation.Submission{ReporterID: stranger, RideID: ride, Category: "other", Description: "x"}, moderation.ErrNotParticipant},
		{"unknown ride", moderation.Submission{ReporterID: rider, RideID: uuid.New(), Category: "other", Description: "x"}, moderation.ErrNotFound},
		{"unknown category", moderation.Submission{ReporterID: rider, RideID: ride, Category: "made_up", Description: "x"}, moderation.ErrInvalidCategory},
		{"empty", moderation.Submission{ReporterID: rider, RideID: ride, Category: "other", Description: "  "}, moderation.ErrInvalidDescription},
		{"driver-only category against a rider", moderation.Submission{ReporterID: driver, RideID: ride, Category: "unsafe_driving", Description: "x"}, moderation.ErrWrongParty},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := w.service.Submit(t.Context(), tc.sub); !errors.Is(err, tc.want) {
				t.Errorf("Submit = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestReportsAreRateLimited(t *testing.T) {
	w := newWorld(t)
	ride, rider, _ := w.finishedRide(t)
	categories := []string{"harassment_or_abuse", "sexual_misconduct", "discrimination", "violence_or_threat", "fraud_or_scam", "payment_dispute", "privacy_violation", "property_damage", "off_platform_solicitation", "other"}
	for _, category := range categories {
		if _, err := w.service.Submit(t.Context(), moderation.Submission{ReporterID: rider, RideID: ride, Category: category, Description: "x"}); err != nil {
			t.Fatalf("Submit %s: %v", category, err)
		}
	}
	_, err := w.service.Submit(t.Context(), moderation.Submission{ReporterID: rider, RideID: ride, Category: "fraud_or_scam", Description: "x"})
	if !errors.Is(err, moderation.ErrRateLimited) {
		t.Errorf("Submit = %v", err)
	}
}

func TestReviewAppliesPenaltyOrNothing(t *testing.T) {
	w := newWorld(t)
	ride, rider, driver := w.finishedRide(t)
	filed, err := w.service.Submit(t.Context(), moderation.Submission{ReporterID: rider, RideID: ride, Category: "other", Description: "x"})
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	staff := w.seed.User(t, "ops")
	// A suspension with no end must fail without marking the report resolved.
	err = w.service.Review(t.Context(), filed.ID, moderation.Decision{Decision: moderation.DecisionSuspension, Actor: staff})
	if !errors.Is(err, moderation.ErrInvalidEnd) {
		t.Fatalf("Review = %v", err)
	}
	report, err := w.service.GetReport(t.Context(), filed.ID)
	if err != nil || report.Status != moderation.StatusSubmitted {
		t.Fatalf("report after failed review = %+v, %v", report, err)
	}
	err = w.service.Review(t.Context(), filed.ID, moderation.Decision{Decision: moderation.DecisionBan, Actor: staff})
	if err != nil {
		t.Fatalf("Review: %v", err)
	}
	if got := w.status(t, driver); got != "banned" {
		t.Errorf("driver = %s", got)
	}
	if err := w.service.Review(t.Context(), filed.ID, moderation.Decision{Decision: moderation.DecisionDismiss, Actor: staff}); !errors.Is(err, moderation.ErrReportClosed) {
		t.Errorf("second ruling = %v", err)
	}
}

func TestStaffCannotActOnTheirOwnCase(t *testing.T) {
	w := newWorld(t)
	ride, rider, driver := w.finishedRide(t)
	filed, err := w.service.Submit(t.Context(), moderation.Submission{ReporterID: rider, RideID: ride, Category: "other", Description: "x"})
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	for name, actor := range map[string]uuid.UUID{"the accused": driver, "the reporter": rider} {
		t.Run(name, func(t *testing.T) {
			if err := w.service.Review(t.Context(), filed.ID, moderation.Decision{Decision: moderation.DecisionDismiss, Actor: actor}); !errors.Is(err, moderation.ErrConflictOfInterest) {
				t.Errorf("Review = %v", err)
			}
		})
	}
}
