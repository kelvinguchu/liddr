package subscriptions_test

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/subscriptions"
)

func TestPayPromptsTheDriversOwnPhoneForTheCategoryPrice(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	payment := h.pay(t, driver)

	if payment.Status != "pending_callback" || payment.AmountKES != 1000 {
		t.Errorf("payment = %+v", payment)
	}
	if h.daraja.lastAmount != 1000 || h.daraja.lastPhone != phone {
		t.Errorf("sent %v to %q, want 1000 to %q", h.daraja.lastAmount, h.daraja.lastPhone, phone)
	}
}

func TestPayRequiresApproval(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "pending")
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrNotVerified) {
		t.Errorf("Pay = %v, want ErrNotVerified", err)
	}
	if got := h.daraja.stkCalls.Load(); got != 0 {
		t.Errorf("prompts sent = %d, want 0", got)
	}
}

func TestPriceChangeReachesAnOpenWeek(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.reference(t, driver) // The week is opened at the launch price.

	h.exec(t, `UPDATE vehicle_categories SET weekly_subscription_kes = 10 WHERE slug = 'motorbike'`)
	payment := h.pay(t, driver)

	if payment.AmountKES != 10 || h.daraja.lastAmount != 10 {
		t.Errorf("charged %d (sent %v), want the test price of 10", payment.AmountKES, h.daraja.lastAmount)
	}
}

func TestOnlyOnePromptAtATime(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")

	var wg sync.WaitGroup
	var ok atomic.Int32
	for range 8 {
		wg.Go(func() {
			if _, err := h.svc.Pay(t.Context(), driver); err == nil {
				ok.Add(1)
			} else if !errors.Is(err, subscriptions.ErrPaymentPending) {
				t.Errorf("Pay = %v", err)
			}
		})
	}
	wg.Wait()
	if ok.Load() != 1 || h.daraja.stkCalls.Load() != 1 {
		t.Errorf("successes = %d, prompts = %d, want 1 and 1", ok.Load(), h.daraja.stkCalls.Load())
	}
}

func TestPayIsRefusedOnceTheWeekIsPaid(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.pay(t, driver)
	h.handleSTK(t, stkBody("ws_1", 0, 1000, "254700000001"))
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrAlreadyActive) {
		t.Errorf("Pay = %v, want ErrAlreadyActive", err)
	}
}

func TestDefiniteRefusalAllowsARetry(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.daraja.setSTK(400, `{"errorCode":"400.002.02"}`)
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrPaymentRefused) {
		t.Fatalf("Pay = %v, want ErrPaymentRefused", err)
	}
	h.daraja.setSTK(200, "")
	h.pay(t, driver)
}

// The legacy backend marked this failed, so a retry could charge the driver twice.
func TestUnknownOutcomeBlocksRetry(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.daraja.setSTK(502, "bad gateway")

	first := h.pay(t, driver)
	if first.Status != "initiated" {
		t.Errorf("status = %q, want initiated", first.Status)
	}
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrPaymentPending) {
		t.Errorf("retry = %v, want ErrPaymentPending", err)
	}
	if got := h.daraja.stkCalls.Load(); got != 1 {
		t.Errorf("prompts sent = %d, want 1", got)
	}
}

func TestPaymentAttemptsAreLimited(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.daraja.setSTK(400, `{}`)
	for range 5 {
		if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrPaymentRefused) {
			t.Fatalf("Pay = %v", err)
		}
	}
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrRateLimited) {
		t.Errorf("sixth attempt = %v, want ErrRateLimited", err)
	}
	h.clock.Advance(time.Hour)
	if _, err := h.svc.Pay(t.Context(), driver); !errors.Is(err, subscriptions.ErrPaymentRefused) {
		t.Errorf("after an hour = %v, want the limit lifted", err)
	}
}

func TestWeeksFollowNairobiTime(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")

	// Sunday 21:30 UTC is already Monday 00:30 in Nairobi.
	h.clock.Set(time.Date(2026, 11, 15, 21, 30, 0, 0, time.UTC))
	summary, err := h.svc.Current(t.Context(), driver)
	if err != nil {
		t.Fatalf("Current: %v", err)
	}
	if got := summary.WeekStart.Format(time.DateOnly); got != "2026-11-16" {
		t.Errorf("week start = %s, want 2026-11-16", got)
	}
	if got := summary.WeekEnd.Format(time.DateOnly); got != "2026-11-22" {
		t.Errorf("week end = %s, want 2026-11-22", got)
	}
}

func TestReferenceFitsDaraja(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	if got := h.reference(t, driver); len(got) > 12 || len(got) < 8 {
		t.Errorf("reference %q does not fit the 12 character limit", got)
	}
}

func TestCallbackTokenCheck(t *testing.T) {
	h := newHarness(t)
	if !h.svc.VerifyCallbackToken(callbackToken) {
		t.Error("the configured token was refused")
	}
	for _, token := range []string{"", "wrong", callbackToken + "x"} {
		if h.svc.VerifyCallbackToken(token) {
			t.Errorf("token %q was accepted", token)
		}
	}
}
