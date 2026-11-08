package subscriptions_test

import (
	"errors"
	"testing"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/payments"
)

func TestSTKSuccessActivatesTheDriver(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	payment := h.pay(t, driver)

	h.handleSTK(t, stkBody("ws_1", 0, 1000, phone))

	if got := h.paymentStatus(t, payment.ID); got != "success" {
		t.Errorf("payment = %q", got)
	}
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("driver = %q", got)
	}
}

func TestSTKReplaysAreHarmless(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	h.pay(t, driver)
	for range 3 {
		h.handleSTK(t, stkBody("ws_1", 0, 1000, phone))
	}
	if got := h.activeWeeks(t, driver); got != "1" {
		t.Errorf("active weeks = %s, want 1", got)
	}
	if got := h.scalar(t, `SELECT count(*)::text FROM audit_events WHERE action = 'subscription.activated'`); got != "1" {
		t.Errorf("activations audited = %s, want 1", got)
	}
}

func TestSTKIntegrity(t *testing.T) {
	tests := []struct {
		name       string
		amount     any
		phone      string
		wantStatus string
		activates  bool
	}{
		{"exact match", 1000, "SELF", "success", true},
		{"masked phone still activates", 1000, "2547****0001", "success", true},
		{"missing phone still activates", 1000, "", "success", true},
		{"short payment", 999, "SELF", "needs_review", false},
		{"overpayment", 1001, "SELF", "needs_review", false},
		{"a different full phone", 1000, "254711111111", "needs_review", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			driver, own := h.newDriver(t, "approved")
			payment := h.pay(t, driver)
			phone := tt.phone
			if phone == "SELF" {
				phone = own
			}
			h.handleSTK(t, stkBody("ws_1", 0, tt.amount, phone))

			if got := h.paymentStatus(t, payment.ID); got != tt.wantStatus {
				t.Errorf("payment = %q, want %q", got, tt.wantStatus)
			}
			if got := h.driverStatus(t, driver) == "active"; got != tt.activates {
				t.Errorf("activated = %v, want %v", got, tt.activates)
			}
		})
	}
}

func TestFailureCodesMapToStatuses(t *testing.T) {
	for code, want := range map[int]string{1032: "cancelled", 1037: "timeout", 1: "failed"} {
		h := newHarness(t)
		driver, _ := h.newDriver(t, "approved")
		payment := h.pay(t, driver)
		h.handleSTK(t, stkBody("ws_1", code, 0, ""))
		if got := h.paymentStatus(t, payment.ID); got != want {
			t.Errorf("code %d = %q, want %q", code, got, want)
		}
	}
}

func TestLateSuccessOverridesFailure(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.handleSTK(t, stkBody("ws_1", 1037, 0, ""))
	h.handleSTK(t, stkBody("ws_1", 0, 1000, phone))

	if got := h.paymentStatus(t, payment.ID); got != "success" {
		t.Errorf("payment = %q", got)
	}
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("driver = %q", got)
	}
}

func TestLateFailureNeverOverridesSuccess(t *testing.T) {
	h := newHarness(t)
	driver, phone := h.newDriver(t, "approved")
	payment := h.pay(t, driver)
	h.handleSTK(t, stkBody("ws_1", 0, 1000, phone))
	h.handleSTK(t, stkBody("ws_1", 1032, 0, ""))
	if got := h.paymentStatus(t, payment.ID); got != "success" {
		t.Errorf("payment = %q", got)
	}
}

func TestUnknownCheckoutIsKeptForOperations(t *testing.T) {
	h := newHarness(t)
	h.handleSTK(t, stkBody("ws_ghost", 0, 500, "254712345678"))
	if got := h.scalar(t, `SELECT reason FROM mpesa_unmatched_callbacks WHERE external_ref = 'ws_ghost'`); got != "unknown_checkout" {
		t.Errorf("reason = %q", got)
	}
}

func TestInvalidCallbackIsRefused(t *testing.T) {
	h := newHarness(t)
	if err := h.svc.HandleSTK(t.Context(), []byte(`{}`)); !errors.Is(err, payments.ErrInvalidCallback) {
		t.Errorf("HandleSTK = %v, want ErrInvalidCallback", err)
	}
}

func TestPaybillActivatesByReferenceIgnoringCase(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	reference := h.reference(t, driver)
	h.handleC2B(t, c2bBody("TX1", " "+lower(reference), "1000.00"))
	if got := h.driverStatus(t, driver); got != "active" {
		t.Errorf("driver = %q", got)
	}
}

func lower(s string) string {
	out := []byte(s)
	for i, c := range out {
		if c >= 'A' && c <= 'Z' {
			out[i] = c + 32
		}
	}
	return string(out)
}

func TestPaybillReplayIsCountedOnce(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	reference := h.reference(t, driver)
	for range 3 {
		h.handleC2B(t, c2bBody("TX1", reference, 1000))
	}
	if got := h.activeWeeks(t, driver); got != "1" {
		t.Errorf("active weeks = %s, want 1", got)
	}
}

// Both cases are real money the legacy backend answered with an error and forgot.
func TestUnapplicablePaybillMoneyIsKeptForOperations(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	reference := h.reference(t, driver)

	h.handleC2B(t, c2bBody("TX1", "NOSUCHREF", 1000))
	h.handleC2B(t, c2bBody("TX2", reference, 900))

	for transaction, want := range map[string]string{"TX1": "unknown_reference", "TX2": "amount_mismatch"} {
		if got := h.scalar(t, `SELECT reason FROM mpesa_unmatched_callbacks WHERE external_ref = $1`, transaction); got != want {
			t.Errorf("%s reason = %q, want %q", transaction, got, want)
		}
	}
	if got := h.driverStatus(t, driver); got != "inactive" {
		t.Errorf("driver = %q, want inactive", got)
	}
}

func TestSecondPaymentCreditsNextWeek(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	reference := h.reference(t, driver)
	h.handleC2B(t, c2bBody("TX1", reference, 1000))
	h.handleC2B(t, c2bBody("TX2", reference, 1000))

	if got := h.activeWeeks(t, driver); got != "2" {
		t.Fatalf("active weeks = %s, want 2", got)
	}
	got := h.scalar(t, `SELECT max(week_start)::text FROM subscriptions WHERE driver_id = $1 AND status = 'active'`, driver)
	if got != "2026-11-16" {
		t.Errorf("latest week = %s, want 2026-11-16", got)
	}
}

func TestPaymentForAPastWeekCreditsTheCurrentWeek(t *testing.T) {
	h := newHarness(t)
	driver, _ := h.newDriver(t, "approved")
	oldReference := h.reference(t, driver)

	h.clock.Advance(8 * 24 * time.Hour)
	h.handleC2B(t, c2bBody("TX1", oldReference, 1000))

	if got := h.scalar(t, `SELECT status FROM subscriptions WHERE reference = $1`, oldReference); got != "pending" {
		t.Errorf("past week = %q, want it left unreactivated", got)
	}
	got := h.scalar(t, `SELECT week_start::text FROM subscriptions WHERE driver_id = $1 AND status = 'active'`, driver)
	if got != "2026-11-16" {
		t.Errorf("credited week = %s, want 2026-11-16", got)
	}
	if got := h.scalar(t, `SELECT s.week_start::text FROM subscription_payments p JOIN subscriptions s ON s.id = p.subscription_id WHERE p.receipt = 'TX1'`); got != "2026-11-16" {
		t.Errorf("payment linked to %s", got)
	}
}
