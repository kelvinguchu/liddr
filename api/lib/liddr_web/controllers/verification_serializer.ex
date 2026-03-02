defmodule LiddrWeb.VerificationSerializer do
  def start_application(payload) do
    %{
      driver: driver(payload.driver),
      application: %{
        id: payload.application.id,
        status: payload.application.status,
        provider: payload.application.provider,
        submitted_at: payload.application.submitted_at
      }
    }
  end

  def submit_document(payload) do
    %{
      application: %{
        id: payload.application.id,
        status: payload.application.status
      },
      document: document(payload.document)
    }
  end

  def review_application(payload) do
    %{
      application: application(payload.application),
      review: review(payload.review),
      driver: driver(payload.driver)
    }
  end

  def review_document(payload) do
    %{
      document: document(payload.document),
      application: application(payload.application),
      review: review(payload.review),
      driver: driver(payload.driver)
    }
  end

  def review_bulk(results) do
    %{
      count: length(results),
      results: Enum.map(results, &review_document/1)
    }
  end

  def application(application) do
    %{
      id: application.id,
      driver_id: application.driver_id,
      status: application.status,
      provider: application.provider,
      submitted_at: application.submitted_at,
      decided_at: application.decided_at,
      decision_reason: application.decision_reason,
      inserted_at: application.inserted_at
    }
  end

  def review(review) do
    %{
      id: review.id,
      application_id: review.application_id,
      driver_id: review.driver_id,
      reviewer_user_id: review.reviewer_user_id,
      decision: review.decision,
      reason: review.reason,
      decided_at: review.decided_at,
      inserted_at: review.inserted_at
    }
  end

  def document(document) do
    %{
      id: document.id,
      application_id: document.application_id,
      driver_id: document.driver_id,
      document_type: document.document_type,
      version: document.version,
      status: document.status,
      scan_status: document.scan_status,
      scan_engine: document.scan_engine,
      scan_signature: document.scan_signature,
      scanned_at: document.scanned_at,
      reviewed_at: document.reviewed_at,
      rejection_reason: document.rejection_reason,
      expires_on: Map.get(document, :expires_on),
      storage_key: document.storage_key,
      inserted_at: document.inserted_at
    }
  end

  def driver(driver) do
    %{
      user_id: driver.user_id,
      account_status: driver.account_status,
      verification_status: driver.verification_status,
      vehicle_category_id: Map.get(driver, :vehicle_category_id),
      license_no: Map.get(driver, :license_no),
      plate_no: Map.get(driver, :plate_no),
      activated_at: Map.get(driver, :activated_at),
      suspended_at: Map.get(driver, :suspended_at),
      is_available: Map.get(driver, :is_available)
    }
  end
end
