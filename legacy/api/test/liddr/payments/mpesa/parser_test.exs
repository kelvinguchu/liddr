defmodule Liddr.Payments.Mpesa.ParserTest do
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias Liddr.Payments.Mpesa.Parser

  test "parse_stk_callback extracts expected callback values" do
    payload = %{
      "Body" => %{
        "stkCallback" => %{
          "MerchantRequestID" => "29115-34620561-1",
          "CheckoutRequestID" => "ws_CO_191220191020363925",
          "ResultCode" => 0,
          "ResultDesc" => "The service request is processed successfully.",
          "CallbackMetadata" => %{
            "Item" => [
              %{"Name" => "Amount", "Value" => 1500},
              %{"Name" => "MpesaReceiptNumber", "Value" => "NLJ7RT61SV"},
              %{"Name" => "TransactionDate", "Value" => 20_260_301_191_530},
              %{"Name" => "PhoneNumber", "Value" => 254_712_345_678}
            ]
          }
        }
      }
    }

    assert {:ok, parsed} = Parser.parse_stk_callback(payload)
    assert parsed.result_code == 0
    assert parsed.checkout_request_id == "ws_CO_191220191020363925"
    assert parsed.merchant_request_id == "29115-34620561-1"
    assert parsed.result_desc == "The service request is processed successfully."
    assert parsed.amount_kes == D.new("1500")
    assert parsed.mpesa_receipt_number == "NLJ7RT61SV"
    assert parsed.phone_e164 == "254712345678"
  end

  test "payment status mapping covers callback outcomes" do
    assert Parser.payment_status_from_result_code(0) == "success"
    assert Parser.payment_status_from_result_code(1032) == "cancelled"
    assert Parser.payment_status_from_result_code(1037) == "timeout"
    assert Parser.payment_status_from_result_code(1) == "failed"
  end

  test "parse_c2b_callback extracts transaction payload" do
    payload = %{
      "TransID" => "SIK2W3AR4T",
      "TransAmount" => "1000",
      "BillRefNumber" => "LIDDR-SUB-55",
      "MSISDN" => "254725799783",
      "FirstName" => "Jane",
      "MiddleName" => "W",
      "LastName" => "Doe",
      "TransTime" => "20260302141233"
    }

    assert {:ok, parsed} = Parser.parse_c2b_callback(payload)
    assert parsed.transaction_id == "SIK2W3AR4T"
    assert parsed.amount_kes == D.new("1000")
    assert parsed.bill_ref_number == "LIDDR-SUB-55"
    assert parsed.phone_e164 == "254725799783"
    assert parsed.first_name == "Jane"
  end

  test "parse_transaction_status_callback extracts status payload" do
    payload = %{
      "Result" => %{
        "ResultType" => 0,
        "ResultCode" => 0,
        "ResultDesc" => "The service request is processed successfully.",
        "OriginatorConversationID" => "12345-12345-1",
        "ConversationID" => "AG_20260302_0000123",
        "TransactionID" => "SIK2W3AR4T"
      }
    }

    assert {:ok, parsed} = Parser.parse_transaction_status_callback(payload)
    assert parsed.result_code == 0
    assert parsed.transaction_id == "SIK2W3AR4T"
    assert parsed.conversation_id == "AG_20260302_0000123"
  end
end
