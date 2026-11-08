defmodule Liddr.Verification.Onboarding.ApplicationFlow do
  alias Liddr.Verification.Onboarding.ApplicationState
  alias Liddr.Verification.Onboarding.DriverProfile

  def ensure_driver_profile!(driver_user_id, attrs, now) do
    DriverProfile.ensure_driver_profile!(driver_user_id, attrs, now)
  end

  def get_or_create_active_application!(driver_user_id, now) do
    ApplicationState.get_or_create_active_application!(driver_user_id, now)
  end

  def ensure_driver_pending_status!(driver, now) do
    DriverProfile.ensure_driver_pending_status!(driver, now)
  end

  def resolve_application!(driver_user_id, attrs) do
    ApplicationState.resolve_application!(driver_user_id, attrs)
  end

  def next_document_version(application_id, document_type) do
    ApplicationState.next_document_version(application_id, document_type)
  end

  def maybe_promote_application_to_under_review!(application, driver, now) do
    ApplicationState.maybe_promote_application_to_under_review!(application, driver, now)
  end
end
