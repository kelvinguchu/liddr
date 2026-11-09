package ratings_test

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/ratings"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type world struct {
	pool    *pgxpool.Pool
	service *ratings.Service
	seed    *testdb.Seeder
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	w.seed = &testdb.Seeder{Pool: w.pool}
	now := func() time.Time { return w.now }
	w.service = ratings.NewService(ratings.Config{Pool: w.pool, Moderation: moderation.NewService(moderation.Config{Pool: w.pool, Now: now}), Now: now})
	return w
}

func (w *world) ride(t *testing.T, rider, driver uuid.UUID) uuid.UUID {
	t.Helper()
	ride := w.seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: "completed", FareKES: 300, Ended: w.now})
	w.seed.OpenRatings(t, ride, rider, driver, w.now.Add(24*time.Hour))
	return ride
}

func (w *world) score(t *testing.T, user uuid.UUID) (*int32, int32) {
	t.Helper()
	var centi *int32
	var count int32
	if err := w.pool.QueryRow(t.Context(), `SELECT rating_centi, rating_count FROM users WHERE id = $1`, user).Scan(&centi, &count); err != nil {
		t.Fatalf("read score: %v", err)
	}
	return centi, count
}

func TestRatingValidation(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride := w.ride(t, rider, driver)
	stranger := w.seed.User(t, "rider")
	cases := []struct {
		name string
		sub  ratings.Submission
		want error
	}{
		{"score too low", ratings.Submission{RideID: ride, RaterID: rider, Score: 0}, ratings.ErrInvalidScore},
		{"score too high", ratings.Submission{RideID: ride, RaterID: rider, Score: 6}, ratings.ErrInvalidScore},
		{"low score without a reason", ratings.Submission{RideID: ride, RaterID: rider, Score: 3}, ratings.ErrReasonsRequired},
		{"not a tag", ratings.Submission{RideID: ride, RaterID: rider, Score: 3, Tags: []string{"has spaces"}}, ratings.ErrInvalidTags},
		{"too many tags", ratings.Submission{RideID: ride, RaterID: rider, Score: 3, Tags: []string{"aa", "bb", "cc", "dd", "ee", "ff"}}, ratings.ErrInvalidTags},
		{"stranger", ratings.Submission{RideID: ride, RaterID: stranger, Score: 5}, ratings.ErrNotRateable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := w.service.Rate(t.Context(), tc.sub); !errors.Is(err, tc.want) {
				t.Errorf("Rate = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestRatingWindowAndSingleUse(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride := w.ride(t, rider, driver)
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: rider, Score: 5}); err != nil {
		t.Fatalf("Rate: %v", err)
	}
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: rider, Score: 1, Tags: []string{"rude"}}); !errors.Is(err, ratings.ErrNotRateable) {
		t.Errorf("rating twice = %v", err)
	}
	w.now = w.now.Add(24 * time.Hour)
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: driver, Score: 5}); !errors.Is(err, ratings.ErrNotRateable) {
		t.Errorf("rating after the window = %v", err)
	}
	if pending, err := w.service.ListPending(t.Context(), driver); err != nil || len(pending) != 0 {
		t.Errorf("pending after the window = %v, %v", pending, err)
	}
}

func TestScoreIsSmoothedAndHonestAboutExclusions(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	first := w.ride(t, rider, driver)
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: first, RaterID: rider, Score: 1, Tags: []string{"rude"}}); err != nil {
		t.Fatalf("Rate: %v", err)
	}
	centi, count := w.score(t, driver)
	// (1 + 4.8*20) / (1 + 20) = 4.619...
	if centi == nil || *centi != 462 || count != 1 {
		t.Errorf("score = %v/%d, want 462/1", centi, count)
	}
	second := w.ride(t, rider, driver)
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: second, RaterID: rider, Score: 1, Tags: []string{"traffic"}}); err != nil {
		t.Fatalf("Rate: %v", err)
	}
	if centi, count := w.score(t, driver); *centi != 462 || count != 1 {
		t.Errorf("a rating blaming traffic changed the score: %v/%d", *centi, count)
	}
}

func TestNullifyAndReinstate(t *testing.T) {
	w := newWorld(t)
	rider, driver, staff := w.seed.User(t, "rider"), w.seed.User(t, "driver"), w.seed.User(t, "ops")
	ride := w.ride(t, rider, driver)
	if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: rider, Score: 1, Tags: []string{"rude"}}); err != nil {
		t.Fatalf("Rate: %v", err)
	}
	list, err := w.service.List(t.Context(), &driver, false, 10, 0)
	if err != nil || len(list) != 1 {
		t.Fatalf("List = %v, %v", list, err)
	}
	id := list[0].ID
	if err := w.service.Nullify(t.Context(), id, driver, "mine", "r"); !errors.Is(err, ratings.ErrSelfAction) {
		t.Errorf("nullifying your own rating = %v", err)
	}
	if err := w.service.Nullify(t.Context(), id, staff, "false report", "r"); err != nil {
		t.Fatalf("Nullify: %v", err)
	}
	if centi, count := w.score(t, driver); centi != nil || count != 0 {
		t.Errorf("after nullify = %v/%d", centi, count)
	}
	if err := w.service.Reinstate(t.Context(), id, staff, "r"); err != nil {
		t.Fatalf("Reinstate: %v", err)
	}
	if centi, count := w.score(t, driver); centi == nil || *centi != 462 || count != 1 {
		t.Errorf("after reinstate = %v/%d", centi, count)
	}
}

func TestSustainedLowRatingRaisesOneReport(t *testing.T) {
	w := newWorld(t)
	driver := w.seed.User(t, "driver")
	for i := range 40 {
		rider := w.seed.User(t, "rider")
		ride := w.ride(t, rider, driver)
		if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: rider, Score: 1, Tags: []string{"rude"}}); err != nil {
			t.Fatalf("Rate %d: %v", i, err)
		}
	}
	var reports int
	if err := w.pool.QueryRow(t.Context(), `SELECT count(*) FROM reports WHERE reported_id = $1 AND source = 'system' AND reporter_id IS NULL`, driver).Scan(&reports); err != nil {
		t.Fatalf("count: %v", err)
	}
	if reports == 0 || reports > 3 {
		t.Errorf("system reports = %d, want one per rule at most", reports)
	}
}

func TestFiveStarCollusionIsFlagged(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	for i := range 5 {
		ride := w.ride(t, rider, driver)
		if err := w.service.Rate(t.Context(), ratings.Submission{RideID: ride, RaterID: rider, Score: 5}); err != nil {
			t.Fatalf("Rate %d: %v", i, err)
		}
	}
	var key string
	err := w.pool.QueryRow(t.Context(), `SELECT signal_key FROM reports WHERE reported_id = $1`, driver).Scan(&key)
	if want := fmt.Sprintf("rating_abuse:pair_30d:%s", rider); err != nil || key != want {
		t.Errorf("signal = %q, %v, want %q", key, err, want)
	}
}
