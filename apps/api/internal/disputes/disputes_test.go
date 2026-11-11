package disputes_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/disputes"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type world struct {
	pool    *pgxpool.Pool
	service *disputes.Service
	seed    *testdb.Seeder
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	w.seed = &testdb.Seeder{Pool: w.pool}
	now := func() time.Time { return w.now }
	w.service = disputes.NewService(disputes.Config{Pool: w.pool, Moderation: moderation.NewService(moderation.Config{Pool: w.pool, Now: now}), Now: now})
	return w
}

func (w *world) ride(t *testing.T, status string) (ride, rider, driver uuid.UUID) {
	t.Helper()
	rider, driver = w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride = w.seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: status, FareKES: 300, Ended: w.now})
	return ride, rider, driver
}

func (w *world) file(t *testing.T, ride, by uuid.UUID, kind string) uuid.UUID {
	t.Helper()
	filed, err := w.service.Submit(t.Context(), disputes.Submission{RequesterID: by, RideID: ride, Type: kind, Description: "what happened"})
	if err != nil {
		t.Fatalf("Submit: %v", err)
	}
	return filed.ID
}

func TestEligibility(t *testing.T) {
	cases := []struct {
		name    string
		status  string
		kind    string
		advance time.Duration
		want    error
	}{
		{"fare after the ride", "completed", "fare_dispute", time.Hour, nil},
		{"on the 48 hour edge", "completed", "fare_dispute", 48 * time.Hour, nil},
		{"past the window", "completed", "fare_dispute", 49 * time.Hour, disputes.ErrWindowClosed},
		{"safety during the ride", "in_progress", "safety_incident", 0, nil},
		{"fare during the ride", "in_progress", "fare_dispute", 0, disputes.ErrRideNotEligible},
		{"unknown type", "completed", "nonsense", 0, disputes.ErrInvalidType},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			ride, rider, _ := w.ride(t, tc.status)
			w.now = w.now.Add(tc.advance)
			_, err := w.service.Submit(t.Context(), disputes.Submission{RequesterID: rider, RideID: ride, Type: tc.kind, Description: "x"})
			if !errors.Is(err, tc.want) {
				t.Errorf("Submit = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestPerRideLimit(t *testing.T) {
	w := newWorld(t)
	ride, rider, _ := w.ride(t, "completed")
	for range 3 {
		w.file(t, ride, rider, "other")
	}
	_, err := w.service.Submit(t.Context(), disputes.Submission{RequesterID: rider, RideID: ride, Type: "other", Description: "x"})
	if !errors.Is(err, disputes.ErrRideLimit) {
		t.Errorf("Submit = %v", err)
	}
}

func TestRefundsAreCappedAtTheFareThatWasCharged(t *testing.T) {
	cases := []struct {
		name   string
		out    string
		amount *int32
		want   error
		paid   int32
	}{
		{"full is the fare", "refund_full", nil, nil, 300},
		{"partial within the fare", "refund_partial", new(int32(120)), nil, 120},
		{"partial above the fare", "refund_partial", new(int32(301)), disputes.ErrInvalidAmount, 0},
		{"credit above the fare", "credit_note", new(int32(1000)), disputes.ErrInvalidAmount, 0},
		{"partial with no amount", "refund_partial", nil, disputes.ErrInvalidAmount, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			ride, rider, _ := w.ride(t, "completed")
			id := w.file(t, ride, rider, "fare_dispute")
			staff := w.seed.User(t, "ops")
			err := w.service.Resolve(t.Context(), id, disputes.Resolution{Outcome: tc.out, AmountKES: tc.amount, Actor: staff})
			if !errors.Is(err, tc.want) {
				t.Fatalf("Resolve = %v, want %v", err, tc.want)
			}
			var amount int32
			scanErr := w.pool.QueryRow(t.Context(), `SELECT amount_kes FROM dispute_compensations`).Scan(&amount)
			if tc.want == nil && (scanErr != nil || amount != tc.paid) {
				t.Errorf("amount = %d, %v, want %d", amount, scanErr, tc.paid)
			}
			if tc.want != nil && scanErr == nil {
				t.Error("a refused award still created compensation")
			}
			var status string
			if err := w.pool.QueryRow(t.Context(), `SELECT status FROM reports WHERE id = $1`, id).Scan(&status); err != nil {
				t.Fatalf("read status: %v", err)
			}
			if tc.want != nil && status != "submitted" {
				t.Errorf("a refused ruling still closed the case: %s", status)
			}
		})
	}
}

func TestDriverWasNotChargedSoCannotBeRefunded(t *testing.T) {
	w := newWorld(t)
	ride, _, driver := w.ride(t, "completed")
	id := w.file(t, ride, driver, "payment_not_received")
	err := w.service.Resolve(t.Context(), id, disputes.Resolution{Outcome: "refund_full", Actor: w.seed.User(t, "ops")})
	if !errors.Is(err, disputes.ErrNotRefundable) {
		t.Errorf("Resolve = %v", err)
	}
}

func TestCompensationSettlement(t *testing.T) {
	w := newWorld(t)
	ride, rider, _ := w.ride(t, "completed")
	id := w.file(t, ride, rider, "fare_dispute")
	staff := w.seed.User(t, "ops")
	if err := w.service.Resolve(t.Context(), id, disputes.Resolution{Outcome: "refund_full", Actor: staff}); err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	owed, err := w.service.ListForUser(t.Context(), rider, 10, 0)
	if err != nil || len(owed) != 1 {
		t.Fatalf("ListForUser = %v, %v", owed, err)
	}
	compensation := owed[0].ID
	if _, err := w.service.MarkPaid(t.Context(), compensation, disputes.Settlement{Channel: "manual_ops", Reference: "  ", Actor: staff}); !errors.Is(err, disputes.ErrReferenceNeeded) {
		t.Errorf("paid without a reference = %v", err)
	}
	if _, err := w.service.MarkPaid(t.Context(), compensation, disputes.Settlement{Channel: "manual_ops", Reference: "ABC", Actor: rider}); !errors.Is(err, disputes.ErrSelfAction) {
		t.Errorf("beneficiary settling = %v", err)
	}
	if _, err := w.service.MarkPaid(t.Context(), compensation, disputes.Settlement{Channel: "manual_ops", Reference: "ABC", Actor: staff}); err != nil {
		t.Fatalf("MarkPaid: %v", err)
	}
	if _, err := w.service.Cancel(t.Context(), compensation, staff); !errors.Is(err, disputes.ErrAlreadySettled) {
		t.Errorf("cancel after paying = %v", err)
	}
}

func TestTheAccusedSeesLittleAndSafetyReportsNotAtAll(t *testing.T) {
	w := newWorld(t)
	ride, rider, driver := w.ride(t, "completed")
	w.file(t, ride, rider, "fare_dispute")
	w.file(t, ride, rider, "safety_incident")
	seen, err := w.service.ListMine(t.Context(), driver, 10, 0)
	if err != nil {
		t.Fatalf("ListMine: %v", err)
	}
	if len(seen) != 1 || seen[0].Type != "fare_dispute" || seen[0].OpenedByMe {
		t.Errorf("accused sees %+v", seen)
	}
	mine, err := w.service.ListMine(t.Context(), rider, 10, 0)
	if err != nil || len(mine) != 2 {
		t.Errorf("reporter sees %v, %v", mine, err)
	}
}
