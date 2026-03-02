defmodule Liddr.Verification.Onboarding do
  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Verification.Malware
  alias Liddr.Verification.OCR
  alias Liddr.Verification.Onboarding.ApplicationFlow
  alias Liddr.Verification.Onboarding.Requirements
  alias Liddr.Verification.Shared
  alias Liddr.Verification.Uploads
  alias Liddr.Verification.VerificationDocument

  def start_application(driver_user_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      driver = ApplicationFlow.ensure_driver_profile!(driver_user_id, attrs, now)
      application = ApplicationFlow.get_or_create_active_application!(driver_user_id, now)
      driver = ApplicationFlow.ensure_driver_pending_status!(driver, now)

      %{
        driver: driver,
        application: application
      }
    end)
    |> Shared.unwrap_transaction_result()
  end

  def submit_document(driver_user_id, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      driver = Repo.get(Driver, driver_user_id) || Repo.rollback(:driver_profile_not_found)
      requirement = Requirements.resolve_requirement!(attrs)
      application = ApplicationFlow.resolve_application!(driver_user_id, attrs)
      storage_key = Uploads.ensure_storage_key_allowed!(attrs) |> unwrap_or_rollback()
      scan_result = Malware.scan_storage_key(storage_key) |> unwrap_or_rollback()
      document_status = document_status_for_scan(scan_result)
      rejection_reason = rejection_reason_for_scan(scan_result)
      file_mime = Shared.get_value(attrs, :file_mime)

      ocr_result =
        if document_status == "pending_review" do
          OCR.extract_storage_key(
            storage_key,
            file_mime: file_mime,
            document_type: requirement.document_type
          )
          |> unwrap_or_rollback()
        else
          OCR.skipped_result("malware_detected", requirement.document_type)
        end

      next_version =
        ApplicationFlow.next_document_version(application.id, requirement.document_type)

      document_attrs = %{
        "application_id" => application.id,
        "driver_id" => driver_user_id,
        "document_type" => requirement.document_type,
        "version" => next_version + 1,
        "capture_source" => Shared.get_value(attrs, :capture_source) || "camera_live",
        "status" => document_status,
        "storage_key" => storage_key,
        "checksum_sha256" => Shared.get_value(attrs, :checksum_sha256),
        "file_mime" => file_mime,
        "file_size_bytes" => Shared.parse_integer(Shared.get_value(attrs, :file_size_bytes)),
        "expires_on" => Shared.get_value(attrs, :expires_on),
        "ocr_payload" => ocr_result.ocr_payload,
        "extracted_data" => ocr_result.extracted_data,
        "capture_metadata" => Shared.get_value(attrs, :capture_metadata) || %{},
        "scan_status" => scan_result.status,
        "scanned_at" => now,
        "scan_engine" => scan_result.engine,
        "scan_signature" => scan_result.signature,
        "scan_error" => scan_result.error,
        "rejection_reason" => rejection_reason
      }

      document =
        %VerificationDocument{}
        |> VerificationDocument.create_changeset(document_attrs)
        |> Repo.insert()
        |> case do
          {:ok, inserted_document} -> inserted_document
          {:error, changeset} -> Repo.rollback(changeset)
        end

      application =
        if document.status == "pending_review" do
          ApplicationFlow.maybe_promote_application_to_under_review!(application, driver, now)
        else
          application
        end

      %{
        application: application,
        document: document
      }
    end)
    |> Shared.unwrap_transaction_result()
  end

  def get_status(driver_user_id), do: Requirements.get_status(driver_user_id)

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp document_status_for_scan(%{status: "infected"}), do: "rejected"
  defp document_status_for_scan(_scan), do: "pending_review"

  defp rejection_reason_for_scan(%{status: "infected", signature: signature})
       when is_binary(signature),
       do: "Malware detected (#{signature})"

  defp rejection_reason_for_scan(%{status: "infected"}), do: "Malware detected"
  defp rejection_reason_for_scan(_scan), do: nil
end
