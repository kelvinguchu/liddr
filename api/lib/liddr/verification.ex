defmodule Liddr.Verification do
  alias Liddr.Verification.Applications
  alias Liddr.Verification.Documents
  alias Liddr.Verification.Onboarding
  alias Liddr.Verification.Uploads

  def start_application(driver_user_id, attrs),
    do: Onboarding.start_application(driver_user_id, attrs)

  def submit_document(driver_user_id, attrs),
    do: Onboarding.submit_document(driver_user_id, attrs)

  def prepare_document_upload(driver_user_id, attrs),
    do: Uploads.prepare_document_upload(driver_user_id, attrs)

  def get_status(driver_user_id), do: Onboarding.get_status(driver_user_id)

  def list_applications(attrs \\ %{}), do: Applications.list_applications(attrs)

  def review_application(application_id, attrs, reviewer_user_id),
    do: Applications.review_application(application_id, attrs, reviewer_user_id)

  def list_documents(attrs \\ %{}), do: Documents.list_documents(attrs)

  def review_document(document_id, attrs, reviewer_user_id),
    do: Documents.review_document(document_id, attrs, reviewer_user_id)

  def review_documents_bulk(document_ids, attrs, reviewer_user_id),
    do: Documents.review_documents_bulk(document_ids, attrs, reviewer_user_id)
end
