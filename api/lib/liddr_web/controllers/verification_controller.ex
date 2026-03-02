defmodule LiddrWeb.VerificationController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Verification
  alias LiddrWeb.VerificationSerializer

  @error_mappings %{
    missing_vehicle_category_id:
      {:unprocessable_entity, "MISSING_VEHICLE_CATEGORY_ID",
       "vehicle_category_id is required to create a driver profile"},
    driver_profile_not_found:
      {:unprocessable_entity, "DRIVER_PROFILE_NOT_FOUND",
       "Driver profile must be initialized first"},
    invalid_document_type:
      {:unprocessable_entity, "INVALID_DOCUMENT_TYPE",
       "Invalid or inactive verification document type"},
    missing_storage_key:
      {:unprocessable_entity, "MISSING_STORAGE_KEY", "storage_key is required"},
    invalid_storage_key:
      {:unprocessable_entity, "INVALID_STORAGE_KEY",
       "storage_key is invalid for verification uploads"},
    missing_file_mime:
      {:unprocessable_entity, "MISSING_FILE_MIME", "file_mime is required for upload preparation"},
    invalid_file_mime: {:unprocessable_entity, "INVALID_FILE_MIME", "file_mime is not allowed"},
    invalid_file_size_bytes:
      {:unprocessable_entity, "INVALID_FILE_SIZE_BYTES",
       "file_size_bytes must be a positive integer"},
    file_too_large:
      {:unprocessable_entity, "FILE_TOO_LARGE", "file_size_bytes exceeds configured upload limit"},
    gcs_bucket_not_configured:
      {:unprocessable_entity, "GCS_BUCKET_NOT_CONFIGURED",
       "Verification upload bucket is not configured"},
    gcp_credentials_missing:
      {:unprocessable_entity, "GCP_CREDENTIALS_MISSING",
       "Google Cloud credentials are not configured"},
    gcp_credentials_unreadable:
      {:unprocessable_entity, "GCP_CREDENTIALS_UNREADABLE",
       "Google Cloud credentials file cannot be read"},
    gcp_credentials_invalid:
      {:unprocessable_entity, "GCP_CREDENTIALS_INVALID", "Google Cloud credentials are invalid"},
    invalid_upload_ttl:
      {:unprocessable_entity, "INVALID_UPLOAD_TTL", "Configured upload TTL is invalid"},
    gcs_signing_failed:
      {:unprocessable_entity, "GCS_SIGNING_FAILED", "Unable to sign upload URL"},
    malware_scan_unavailable:
      {:service_unavailable, "MALWARE_SCAN_UNAVAILABLE",
       "Malware scanning service is temporarily unavailable"},
    malware_scan_failed:
      {:unprocessable_entity, "MALWARE_SCAN_FAILED", "Unable to complete malware scan"},
    malware_source_unavailable:
      {:unprocessable_entity, "MALWARE_SOURCE_UNAVAILABLE",
       "Unable to read uploaded file for malware scanning"},
    no_active_application:
      {:unprocessable_entity, "NO_ACTIVE_APPLICATION", "No active verification application found"},
    application_not_found:
      {:not_found, "APPLICATION_NOT_FOUND", "Verification application not found"}
  }

  def start_application(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Verification.start_application(driver_user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: VerificationSerializer.start_application(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def submit_document(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Verification.submit_document(driver_user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: VerificationSerializer.submit_document(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def presign_upload(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Verification.prepare_document_upload(driver_user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: payload})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def status(conn, _params) do
    driver_user_id = conn.assigns.current_user.id

    case Verification.get_status(driver_user_id) do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@error_mappings, reason) do
      {status, code, message} ->
        error_response(conn, status, code, message)

      nil ->
        error_response(
          conn,
          :unprocessable_entity,
          "VERIFICATION_ERROR",
          "Unable to process verification request"
        )
    end
  end

  defp render_error(conn, _unknown) do
    error_response(
      conn,
      :unprocessable_entity,
      "VERIFICATION_ERROR",
      "Unable to process verification request"
    )
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
