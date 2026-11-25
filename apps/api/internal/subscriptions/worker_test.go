package subscriptions_test

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func (h *harness) reconcile(t *testing.T) {
	t.Helper()
	if err := h.svc.Reconcile(t.Context()); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
}

func (h *harness) expire(t *testing.T) {
	t.Helper()
	if err := h.svc.ExpireLapsed(t.Context()); err != nil {
		t.Fatalf("ExpireLapsed: %v", err)
	}
}

func TestReconcileAppliesAMissedCallback(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.daraja.setQuery(200, `{"ResultCode":"0","ResultDesc":"ok"}`)

	h.clock.Advance(89 * time.Second)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "pending_callback" {
		t.Fatalf("checked too early: %q", got)
	}

	h.clock.Advance(time.Second)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "success" {
		t.Errorf("payment = %q", got)
	}
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("driver = %q", got)
	}
}

func TestReconcileRecordsAFinalFailure(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.daraja.setQuery(200, `{"ResultCode":"1032","ResultDesc":"cancelled"}`)
	h.clock.Advance(2 * time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "cancelled" {
		t.Errorf("payment = %q", got)
	}
}

func TestStillProcessingIsNotAFailure(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.daraja.setQuery(500, `{"errorCode":"500.001.1001"}`)
	h.clock.Advance(2 * time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "pending_callback" {
		t.Errorf("payment = %q, want it still open", got)
	}
}

func TestGivingUpStillAllowsALateSuccess(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	payment := h.pay(t, driver)

	h.clock.Advance(30 * time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "timeout" {
		t.Fatalf("payment = %q, want timeout", got)
	}
	h.handleSTK(t, stkBody("ws_1", 0, 1000, phone))
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("driver = %q", got)
	}
}

// A prompt dies on the phone within about a minute. If M-Pesa still says
// "processing" well after that, the driver must be able to try again rather
// than wait half an hour for the stuck prompt to be given up.
func TestAStuckPromptIsReleasedForARetry(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.daraja.setQuery(500, `{"errorCode":"500.001.1001"}`)

	h.clock.Advance(3 * time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "timeout" {
		t.Fatalf("payment = %q after 3 minutes of processing, want timeout", got)
	}
	h.pay(t, driver)
}

func TestUnknownOutcomeIsReleasedEventually(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.daraja.setSTK(502, "bad gateway")
	payment := h.pay(t, driver)

	h.clock.Advance(4 * time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "initiated" {
		t.Fatalf("released too early: %q", got)
	}
	h.clock.Advance(time.Minute)
	h.reconcile(t)
	if got := h.paymentStatus(t, payment.ID); got != "timeout" {
		t.Errorf("payment = %q, want timeout", got)
	}
	h.daraja.setSTK(200, "")
	h.pay(t, driver)
}

func TestReconcileChecksAPaymentOncePerMinute(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.pay(t, driver)
	h.clock.Advance(2 * time.Minute)
	h.reconcile(t)
	first := h.scalar(t, `SELECT last_checked_at::text FROM subscription_payments`)

	h.clock.Advance(30 * time.Second)
	h.reconcile(t)
	if got := h.scalar(t, `SELECT last_checked_at::text FROM subscription_payments`); got != first {
		t.Errorf("checked again after 30s: %s then %s", first, got)
	}
}

func (h *harness) activeDriver(t *testing.T) uuid.UUID {
	t.Helper()
	driver, _ := h.newDriver(t, "approved")
	h.handleC2B(t, c2bBody("TX-"+driver.String(), h.reference(t, driver), 1000))
	h.exec(t, `UPDATE drivers SET is_online = true WHERE user_id = $1`, driver)
	return driver
}

func TestWeekEndGraceThenOffline(t *testing.T) {
	h := newHarness(t)
	driver := h.activeDriver(t)
	online := func() string {
		return h.scalar(t, `SELECT is_online::text FROM drivers WHERE user_id = $1`, driver)
	}

	// Sunday 23:00 in Nairobi: this week still covers the driver.
	h.clock.Set(time.Date(2026, 11, 15, 20, 0, 0, 0, time.UTC))
	h.expire(t)
	if got := h.driverStatus(t, driver); got != "active" {
		t.Fatalf("Sunday status = %q, want active", got)
	}

	// Monday 05:59: inside the six hour grace.
	h.clock.Set(time.Date(2026, 11, 16, 2, 59, 0, 0, time.UTC))
	h.expire(t)
	if got := h.driverStatus(t, driver); got != "grace" {
		t.Errorf("grace status = %q", got)
	}
	if got := online(); got != "true" {
		t.Errorf("online during grace = %s", got)
	}

	// Monday 06:00: grace is over.
	h.clock.Set(time.Date(2026, 11, 16, 3, 0, 0, 0, time.UTC))
	h.expire(t)
	if got := h.driverStatus(t, driver); got != "inactive" {
		t.Errorf("status after grace = %q", got)
	}
	if got := online(); got != "false" {
		t.Errorf("online after grace = %s", got)
	}
}

func TestPaidNextWeekKeepsDriverActive(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	reference := h.reference(t, driver)
	h.handleC2B(t, c2bBody("TX1", reference, 1000))
	h.handleC2B(t, c2bBody("TX2", reference, 1000))

	h.clock.Set(time.Date(2026, 11, 16, 9, 0, 0, 0, time.UTC))
	h.expire(t)
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("status = %q, want active on the prepaid week", got)
	}
	if got := h.activeWeeks(t, driver); got != "1" {
		t.Errorf("active weeks = %s, want the old week expired", got)
	}
}

func TestPayingDuringGraceRestoresActive(t *testing.T) {
	h := newHarness(t)
	driver := h.activeDriver(t)
	h.clock.Set(time.Date(2026, 11, 16, 1, 0, 0, 0, time.UTC))
	h.expire(t)
	h.handleC2B(t, c2bBody("TX-new", h.reference(t, driver), 1000))
	h.expire(t)
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("status = %q", got)
	}
}

// Safaricom drops callbacks to addresses that name M-Pesa or Safaricom, or
// look like commands, so none of the addresses Liddr hands it may.
func TestCallbackAddressesAvoidWordsDarajaRefuses(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.pay(t, driver)
	h.daraja.mu.Lock()
	stk := h.daraja.lastCallbackURL
	h.daraja.mu.Unlock()
	validation, confirmation := h.svc.C2BURLs()
	for _, address := range []string{stk, validation, confirmation} {
		if address == "" {
			t.Fatal("no callback address was sent")
		}
		for _, word := range []string{"mpesa", "m-pesa", "safaricom", "exe", "cmd", "sql", "query"} {
			if strings.Contains(strings.ToLower(address), word) {
				t.Errorf("%s contains %q", address, word)
			}
		}
	}
}

// Daraja allows at most 13 characters of description and 12 of account
// reference on a prompt.
func TestPromptFitsDarajaFieldLimits(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	h.pay(t, driver)
	h.daraja.mu.Lock()
	description, reference := h.daraja.lastDescription, h.daraja.lastReference
	h.daraja.mu.Unlock()
	if n := len(description); n == 0 || n > 13 {
		t.Errorf("TransactionDesc %q is %d characters, want 1 to 13", description, n)
	}
	if n := len(reference); n == 0 || n > 12 {
		t.Errorf("AccountReference %q is %d characters, want 1 to 12", reference, n)
	}
}
