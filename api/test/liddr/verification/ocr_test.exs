defmodule Liddr.Verification.OCRTest do
  use ExUnit.Case, async: false

  alias Liddr.Verification.OCR

  setup do
    original_ocr_enabled = System.get_env("OCR_ENABLED")
    original_ocr_pdf_enabled = System.get_env("OCR_PDF_ENABLED")

    on_exit(fn ->
      if is_nil(original_ocr_enabled) do
        System.delete_env("OCR_ENABLED")
      else
        System.put_env("OCR_ENABLED", original_ocr_enabled)
      end

      if is_nil(original_ocr_pdf_enabled) do
        System.delete_env("OCR_PDF_ENABLED")
      else
        System.put_env("OCR_PDF_ENABLED", original_ocr_pdf_enabled)
      end
    end)

    :ok
  end

  test "returns skipped when OCR is disabled" do
    System.put_env("OCR_ENABLED", "false")

    assert {:ok, result} =
             OCR.extract_storage_key("verification/docs/1/national_id_front/front.jpg",
               file_mime: "image/jpeg",
               document_type: "national_id_front"
             )

    assert result.ocr_payload["status"] == "skipped"
    assert result.ocr_payload["reason"] == "disabled"
    assert result.extracted_data["status"] == "skipped"
  end

  test "returns skipped when PDF OCR is disabled" do
    System.put_env("OCR_ENABLED", "true")
    System.put_env("OCR_PDF_ENABLED", "false")

    assert {:ok, result} =
             OCR.extract_storage_key("verification/docs/1/good_conduct_certificate/cert.pdf",
               file_mime: "application/pdf",
               document_type: "good_conduct_certificate"
             )

    assert result.ocr_payload["status"] == "skipped"
    assert result.ocr_payload["reason"] == "pdf_ocr_disabled"
    assert result.extracted_data["status"] == "skipped"
  end

  test "returns skipped when file mime is unsupported" do
    System.put_env("OCR_ENABLED", "true")
    System.put_env("OCR_PDF_ENABLED", "true")

    assert {:ok, result} =
             OCR.extract_storage_key("verification/docs/1/random/file.txt",
               file_mime: "text/plain",
               document_type: "good_conduct_certificate"
             )

    assert result.ocr_payload["status"] == "skipped"
    assert result.ocr_payload["reason"] == "unsupported_file_mime"
    assert result.extracted_data["status"] == "skipped"
  end
end
