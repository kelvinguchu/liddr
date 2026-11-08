// Package payments talks to Safaricom's Daraja API and parses its callbacks.
package payments

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

// ErrInvalidCallback reports a callback that cannot be understood.
var ErrInvalidCallback = errors.New("invalid m-pesa callback")

// Daraja result codes with their own meaning.
const (
	ResultSuccess    = 0
	ResultCancelled  = 1032
	ResultTimeout    = 1037
	ResultProcessing = 4999
)

// STKCallback is the outcome of an STK push.
type STKCallback struct {
	MerchantRequestID string
	CheckoutRequestID string
	ResultCode        int32
	ResultDesc        string
	// AmountKES is nil when absent or not a whole number of shillings.
	AmountKES *int32
	Receipt   string
	// Phone is empty when absent or masked, as Safaricom now does for some
	// callbacks. A masked number is not evidence of a mismatch.
	Phone string
}

// flexValue is a scalar that Daraja may send as a string or a number.
type flexValue string

// UnmarshalJSON accepts strings and numbers and stores their text form.
func (v *flexValue) UnmarshalJSON(data []byte) error {
	text := strings.TrimSpace(string(data))
	if text == "null" {
		*v = ""
		return nil
	}
	if strings.HasPrefix(text, "{") || strings.HasPrefix(text, "[") {
		return errors.New("expected a scalar")
	}
	if strings.HasPrefix(text, `"`) {
		var unquoted string
		if err := json.Unmarshal(data, &unquoted); err != nil {
			return err
		}
		text = strings.TrimSpace(unquoted)
	}
	*v = flexValue(text)
	return nil
}

func (v flexValue) wholeNumber() *int32 {
	value, err := strconv.ParseFloat(string(v), 64)
	if err != nil || value <= 0 || value > 1e9 || value != float64(int32(value)) {
		return nil
	}
	return new(int32(value))
}

func (v flexValue) phone() string {
	digits := string(v)
	if len(digits) != 12 || !strings.HasPrefix(digits, "254") {
		return ""
	}
	for _, c := range digits {
		if c < '0' || c > '9' {
			return ""
		}
	}
	return digits
}

// ParseSTKCallback reads a Daraja STK callback body.
func ParseSTKCallback(body []byte) (STKCallback, error) {
	var parsed struct {
		Body struct {
			Callback struct {
				MerchantRequestID flexValue  `json:"MerchantRequestID"`
				CheckoutRequestID flexValue  `json:"CheckoutRequestID"`
				ResultCode        *flexValue `json:"ResultCode"`
				ResultDesc        flexValue  `json:"ResultDesc"`
				Metadata          struct {
					Items []struct {
						Name  string    `json:"Name"`
						Value flexValue `json:"Value"`
					} `json:"Item"`
				} `json:"CallbackMetadata"`
			} `json:"stkCallback"`
		} `json:"Body"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return STKCallback{}, ErrInvalidCallback
	}
	callback := parsed.Body.Callback
	if callback.ResultCode == nil || callback.CheckoutRequestID == "" {
		return STKCallback{}, ErrInvalidCallback
	}
	code, err := strconv.ParseInt(string(*callback.ResultCode), 10, 32)
	if err != nil {
		return STKCallback{}, ErrInvalidCallback
	}

	result := STKCallback{
		MerchantRequestID: string(callback.MerchantRequestID),
		CheckoutRequestID: string(callback.CheckoutRequestID),
		ResultCode:        int32(code),
		ResultDesc:        string(callback.ResultDesc),
	}
	for _, item := range callback.Metadata.Items {
		switch item.Name {
		case "Amount":
			result.AmountKES = item.Value.wholeNumber()
		case "MpesaReceiptNumber":
			result.Receipt = string(item.Value)
		case "PhoneNumber":
			result.Phone = item.Value.phone()
		}
	}
	return result, nil
}

// C2BCallback is a paybill payment confirmation.
type C2BCallback struct {
	TransactionID    string
	AmountKES        *int32
	AccountReference string
	Phone            string
}

// ParseC2BCallback reads a Daraja C2B confirmation body.
func ParseC2BCallback(body []byte) (C2BCallback, error) {
	var parsed struct {
		TransID       flexValue `json:"TransID"`
		TransAmount   flexValue `json:"TransAmount"`
		BillRefNumber flexValue `json:"BillRefNumber"`
		MSISDN        flexValue `json:"MSISDN"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.TransID == "" {
		return C2BCallback{}, ErrInvalidCallback
	}
	return C2BCallback{
		TransactionID:    string(parsed.TransID),
		AmountKES:        parsed.TransAmount.wholeNumber(),
		AccountReference: strings.ToUpper(string(parsed.BillRefNumber)),
		Phone:            parsed.MSISDN.phone(),
	}, nil
}

// StatusFromResult maps a Daraja result code to a final payment status.
func StatusFromResult(code int32) string {
	switch code {
	case ResultSuccess:
		return "success"
	case ResultCancelled:
		return "cancelled"
	case ResultTimeout:
		return "timeout"
	default:
		return "failed"
	}
}
