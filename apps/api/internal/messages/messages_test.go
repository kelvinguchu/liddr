package messages_test

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/kelvinguchu/liddr/apps/api/internal/messages"
	"github.com/kelvinguchu/liddr/apps/api/internal/moderation"
	"github.com/kelvinguchu/liddr/apps/api/internal/testdb"
)

type world struct {
	pool    *pgxpool.Pool
	service *messages.Service
	seed    *testdb.Seeder
	now     time.Time
}

func newWorld(t *testing.T) *world {
	t.Helper()
	w := &world{pool: testdb.Pool(t), now: time.Date(2026, 6, 1, 9, 0, 0, 0, time.UTC)}
	w.seed = &testdb.Seeder{Pool: w.pool}
	now := func() time.Time { return w.now }
	w.service = messages.NewService(messages.Config{Pool: w.pool, Moderation: moderation.NewService(moderation.Config{Pool: w.pool, Now: now}), Now: now})
	return w
}

func (w *world) activeRide(t *testing.T, rider, driver uuid.UUID) uuid.UUID {
	t.Helper()
	return w.seed.Ride(t, testdb.Ride{Rider: rider, Driver: new(driver), Status: "accepted", FareKES: 300, Ended: w.now})
}

func (w *world) finish(t *testing.T, ride uuid.UUID) {
	t.Helper()
	if _, err := w.pool.Exec(t.Context(), `UPDATE rides SET status = 'completed', completed_at = now() WHERE id = $1`, ride); err != nil {
		t.Fatalf("finish ride: %v", err)
	}
}

func (w *world) say(t *testing.T, ride, sender uuid.UUID, body string) messages.Message {
	t.Helper()
	message, err := w.service.Send(t.Context(), messages.Draft{RideID: ride, SenderID: sender, Body: body})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	return message
}

func TestSendingRules(t *testing.T) {
	w := newWorld(t)
	rider, driver, stranger := w.seed.User(t, "rider"), w.seed.User(t, "driver"), w.seed.User(t, "rider")
	ride := w.activeRide(t, rider, driver)
	unassigned := w.seed.Ride(t, testdb.Ride{Rider: stranger, Status: "searching", FareKES: 300, Ended: w.now})
	cases := []struct {
		name  string
		draft messages.Draft
		want  error
	}{
		{"stranger", messages.Draft{RideID: ride, SenderID: stranger, Body: "hi"}, messages.ErrNotFound},
		{"unknown ride", messages.Draft{RideID: uuid.New(), SenderID: rider, Body: "hi"}, messages.ErrNotFound},
		{"no driver yet", messages.Draft{RideID: unassigned, SenderID: stranger, Body: "hi"}, messages.ErrNoDriver},
		{"blank", messages.Draft{RideID: ride, SenderID: rider, Body: "   "}, messages.ErrInvalidBody},
		{"unknown quick action", messages.Draft{RideID: ride, SenderID: rider, QuickAction: new("made_up")}, messages.ErrInvalidAction},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := w.service.Send(t.Context(), tc.draft); !errors.Is(err, tc.want) {
				t.Errorf("Send = %v, want %v", err, tc.want)
			}
		})
	}
	quick, err := w.service.Send(t.Context(), messages.Draft{RideID: ride, SenderID: driver, QuickAction: new("arrived")})
	if err != nil || quick.Body != "I have arrived" || quick.SenderRole != "driver" {
		t.Errorf("quick action = %+v, %v", quick, err)
	}
	w.finish(t, ride)
	if _, err := w.service.Send(t.Context(), messages.Draft{RideID: ride, SenderID: rider, Body: "hi"}); !errors.Is(err, messages.ErrClosed) {
		t.Errorf("after the ride = %v", err)
	}
}

func TestMessagesAreRateLimited(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride := w.activeRide(t, rider, driver)
	for range 30 {
		w.say(t, ride, rider, "hello")
	}
	if _, err := w.service.Send(t.Context(), messages.Draft{RideID: ride, SenderID: rider, Body: "again"}); !errors.Is(err, messages.ErrRateLimited) {
		t.Errorf("Send = %v", err)
	}
	w.now = w.now.Add(time.Minute)
	w.say(t, ride, rider, "later")
}

func TestReadAndHideAffectOnlyTheirOwner(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride := w.activeRide(t, rider, driver)
	message := w.say(t, ride, rider, "hello")

	if err := w.service.MarkRead(t.Context(), ride, message.ID, rider); !errors.Is(err, messages.ErrNotRecipient) {
		t.Errorf("sender marking read = %v", err)
	}
	thread, err := w.service.List(t.Context(), ride, driver, 0, 0)
	if err != nil || thread.Unread != 1 {
		t.Fatalf("List = %+v, %v", thread, err)
	}
	for range 2 {
		if err := w.service.MarkRead(t.Context(), ride, message.ID, driver); err != nil {
			t.Errorf("MarkRead = %v", err)
		}
	}
	if err := w.service.Hide(t.Context(), ride, message.ID, driver); err != nil {
		t.Fatalf("Hide: %v", err)
	}
	mine, err := w.service.List(t.Context(), ride, driver, 0, 0)
	if err != nil || len(mine.Messages) != 0 {
		t.Errorf("hider still sees %+v, %v", mine, err)
	}
	theirs, err := w.service.List(t.Context(), ride, rider, 0, 0)
	if err != nil || len(theirs.Messages) != 1 {
		t.Errorf("sender lost the message: %+v, %v", theirs, err)
	}
	stranger := w.seed.User(t, "rider")
	if _, err := w.service.List(t.Context(), ride, stranger, 0, 0); !errors.Is(err, messages.ErrNotFound) {
		t.Errorf("stranger reading = %v", err)
	}
}

func TestReportingCannotBeUsedToSilenceSomeoneAlone(t *testing.T) {
	w := newWorld(t)
	rider, driver := w.seed.User(t, "rider"), w.seed.User(t, "driver")
	ride := w.activeRide(t, rider, driver)
	for range 5 {
		message := w.say(t, ride, driver, "rude")
		if _, err := w.service.Report(t.Context(), ride, message.ID, rider, ""); err != nil {
			t.Fatalf("Report: %v", err)
		}
	}
	w.say(t, ride, driver, "still allowed")

	own := w.say(t, ride, rider, "mine")
	if _, err := w.service.Report(t.Context(), ride, own.ID, rider, ""); !errors.Is(err, messages.ErrOwnMessage) {
		t.Errorf("reporting your own = %v", err)
	}
}

func TestReportsFromSeveralPeopleRestrictMessagesOnly(t *testing.T) {
	w := newWorld(t)
	driver := w.seed.User(t, "driver")
	for range 3 {
		rider := w.seed.User(t, "rider")
		ride := w.activeRide(t, rider, driver)
		message := w.say(t, ride, driver, "rude")
		if _, err := w.service.Report(t.Context(), ride, message.ID, rider, ""); err != nil {
			t.Fatalf("Report: %v", err)
		}
		w.finish(t, ride)
	}
	rider := w.seed.User(t, "rider")
	ride := w.activeRide(t, rider, driver)
	if _, err := w.service.Send(t.Context(), messages.Draft{RideID: ride, SenderID: driver, Body: "hi"}); !errors.Is(err, messages.ErrRestricted) {
		t.Errorf("Send after restriction = %v", err)
	}
	var status string
	if err := w.pool.QueryRow(t.Context(), `SELECT account_status FROM users WHERE id = $1`, driver).Scan(&status); err != nil || status != "active" {
		t.Errorf("a chat restriction changed the account: %s, %v", status, err)
	}
}
