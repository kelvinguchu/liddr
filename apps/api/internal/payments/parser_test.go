package payments

import (
	"errors"
	"testing"

	"github.com/google/go-cmp/cmp"
)

const successBody = `{"Body":{"stkCallback":{"MerchantRequestID":"m-1","CheckoutRequestID":"ws_CO_1","ResultCode":0,"ResultDesc":"Processed",
"CallbackMetadata":{"Item":[{"Name":"Amount","Value":1000.00},{"Name":"MpesaReceiptNumber","Value":"NLJ7RT61SV"},
{"Name":"Balance"},{"Name":"TransactionDate","Value":20191219102115},{"Name":"PhoneNumber","Value":254712345678}]}}}}`

func TestParseSTKCallback(t *testing.T) {
	got, err := ParseSTKCallback([]byte(successBody))
	if err != nil {
		t.Fatalf("ParseSTKCallback: %v", err)
	}
	want := STKCallback{
		MerchantRequestID: "m-1", CheckoutRequestID: "ws_CO_1", ResultCode: 0, ResultDesc: "Processed",
		AmountKES: new(int32(1000)), Receipt: "NLJ7RT61SV", Phone: "254712345678",
	}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("callback mismatch (-got +want):\n%s", diff)
	}
}

func TestParseSTKCallbackVariants(t *testing.T) {
	wrap := func(rest string) string {
		return `{"Body":{"stkCallback":{"CheckoutRequestID":"ws_1","ResultCode":0,"CallbackMetadata":{"Item":[` + rest + `]}}}}`
	}
	tests := []struct {
		name      string
		body      string
		wantPhone string
		wantKES   *int32
	}{
		{"masked phone is treated as absent", wrap(`{"Name":"PhoneNumber","Value":"2547****5678"}`), "", nil},
		{"string phone", wrap(`{"Name":"PhoneNumber","Value":"254712345678"}`), "254712345678", nil},
		{"short phone", wrap(`{"Name":"PhoneNumber","Value":712345678}`), "", nil},
		{"string amount", wrap(`{"Name":"Amount","Value":"1500"}`), "", new(int32(1500))},
		{"fractional amount is unusable", wrap(`{"Name":"Amount","Value":10.5}`), "", nil},
		{"negative amount is unusable", wrap(`{"Name":"Amount","Value":-5}`), "", nil},
		{"huge amount is unusable", wrap(`{"Name":"Amount","Value":1e30}`), "", nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseSTKCallback([]byte(tt.body))
			if err != nil {
				t.Fatalf("ParseSTKCallback: %v", err)
			}
			if got.Phone != tt.wantPhone {
				t.Errorf("Phone = %q, want %q", got.Phone, tt.wantPhone)
			}
			if diff := cmp.Diff(got.AmountKES, tt.wantKES); diff != "" {
				t.Errorf("AmountKES mismatch (-got +want):\n%s", diff)
			}
		})
	}
}

func TestParseSTKCallbackRejectsNonsense(t *testing.T) {
	bodies := map[string]string{
		"not json":          `<xml/>`,
		"empty":             `{}`,
		"no checkout id":    `{"Body":{"stkCallback":{"ResultCode":0}}}`,
		"no result code":    `{"Body":{"stkCallback":{"CheckoutRequestID":"x"}}}`,
		"text result code":  `{"Body":{"stkCallback":{"CheckoutRequestID":"x","ResultCode":"oops"}}}`,
		"object for string": `{"Body":{"stkCallback":{"CheckoutRequestID":{"a":1},"ResultCode":0}}}`,
	}
	for name, body := range bodies {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseSTKCallback([]byte(body)); !errors.Is(err, ErrInvalidCallback) {
				t.Errorf("ParseSTKCallback = %v, want ErrInvalidCallback", err)
			}
		})
	}
}

func TestParseC2BCallback(t *testing.T) {
	body := `{"TransID":"RKT1","TransAmount":"1000.00","BillRefNumber":"ldrabc12345","MSISDN":"254712345678"}`
	got, err := ParseC2BCallback([]byte(body))
	if err != nil {
		t.Fatalf("ParseC2BCallback: %v", err)
	}
	want := C2BCallback{TransactionID: "RKT1", AmountKES: new(int32(1000)), AccountReference: "LDRABC12345", Phone: "254712345678"}
	if diff := cmp.Diff(got, want); diff != "" {
		t.Errorf("callback mismatch (-got +want):\n%s", diff)
	}

	hashed := `{"TransID":"RKT2","TransAmount":"1000","BillRefNumber":"X","MSISDN":"a1b2c3d4e5f6a1b2c3d4e5f6"}`
	if got, err := ParseC2BCallback([]byte(hashed)); err != nil || got.Phone != "" {
		t.Errorf("hashed MSISDN = %+v, %v", got, err)
	}
	if _, err := ParseC2BCallback([]byte(`{"TransAmount":"1"}`)); !errors.Is(err, ErrInvalidCallback) {
		t.Errorf("missing id = %v, want ErrInvalidCallback", err)
	}
}

func TestStatusFromResult(t *testing.T) {
	for code, want := range map[int32]string{0: "success", 1032: "cancelled", 1037: "timeout", 1: "failed", 2001: "failed"} {
		if got := StatusFromResult(code); got != want {
			t.Errorf("StatusFromResult(%d) = %q, want %q", code, got, want)
		}
	}
}

func FuzzParseSTKCallback(f *testing.F) {
	f.Add([]byte(successBody))
	f.Add([]byte(`{"Body":{"stkCallback":{"CheckoutRequestID":"x","ResultCode":1032}}}`))
	f.Fuzz(func(t *testing.T, body []byte) {
		got, err := ParseSTKCallback(body)
		if err != nil {
			return
		}
		if got.CheckoutRequestID == "" {
			t.Fatal("accepted a callback with no checkout id")
		}
		if got.AmountKES != nil && *got.AmountKES <= 0 {
			t.Fatalf("accepted amount %d", *got.AmountKES)
		}
		if got.Phone != "" && len(got.Phone) != 12 {
			t.Fatalf("accepted phone %q", got.Phone)
		}
	})
}

func FuzzParseC2BCallback(f *testing.F) {
	f.Add([]byte(`{"TransID":"RKT1","TransAmount":"1000.00","BillRefNumber":"a","MSISDN":"254712345678"}`))
	f.Fuzz(func(t *testing.T, body []byte) {
		got, err := ParseC2BCallback(body)
		if err == nil && got.TransactionID == "" {
			t.Fatal("accepted a callback with no transaction id")
		}
	})
}
