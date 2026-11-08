defmodule Liddr.Verification.Applications.ReviewTest do
  use Liddr.DataCase, async: true

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Verification.Applications.Review
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationReview

  test "approve sets application approved and activates pending driver" do
    {driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(
        application_status: "under_review"
      )

    assert {:ok, result} =
             Review.review_application(
               application.id,
               %{"decision" => "approve", "reason" => "All checks passed"},
               reviewer.id
             )

    assert result.application.status == "approved"
    assert result.review.decision == "approve"
    assert result.driver.verification_status == "approved"
    assert result.driver.account_status == "active"
    assert not is_nil(result.driver.activated_at)

    event = latest_activity_event!(driver.user_id)
    assert event.reason_code == "approve"
    assert event.new_value == "approved"
  end

  test "reject sets application rejected and driver pending account" do
    {_driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(
        application_status: "under_review"
      )

    assert {:ok, result} =
             Review.review_application(
               application.id,
               %{"decision" => "reject", "reason" => "Failed checks"},
               reviewer.id
             )

    assert result.application.status == "rejected"
    assert result.driver.verification_status == "rejected"
    assert result.driver.account_status == "pending"
    assert result.review.decision == "reject"
  end

  test "request_resubmission sets application and driver back to pending" do
    {_driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(
        application_status: "under_review"
      )

    assert {:ok, result} =
             Review.review_application(
               application.id,
               %{"decision" => "request_resubmission", "reason" => "Upload clearer docs"},
               reviewer.id
             )

    assert result.application.status == "resubmission_required"
    assert result.driver.verification_status == "pending"
    assert result.driver.account_status == "pending"
    assert result.review.decision == "request_resubmission"
  end

  test "suspend sets application suspended and driver suspended/unavailable" do
    {_driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(
        application_status: "under_review"
      )

    assert {:ok, result} =
             Review.review_application(
               application.id,
               %{"decision" => "suspend", "reason" => "Policy violation"},
               reviewer.id
             )

    assert result.application.status == "suspended"
    assert result.driver.verification_status == "suspended"
    assert result.driver.account_status == "suspended"
    assert result.driver.is_available == false
    assert not is_nil(result.driver.suspended_at)
  end

  test "returns invalid_review_decision for unsupported decision" do
    {_driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(
        application_status: "under_review"
      )

    assert {:error, :invalid_review_decision} =
             Review.review_application(application.id, %{"decision" => "invalid"}, reviewer.id)

    assert Repo.get!(VerificationApplication, application.id).status == "under_review"
    assert Repo.aggregate(VerificationReview, :count, :id) == 0
  end

  test "returns application_not_reviewable when status is not reviewable" do
    {_driver, application, reviewer} =
      VerificationFixtures.create_driver_application_and_reviewer!(application_status: "approved")

    assert {:error, :application_not_reviewable} =
             Review.review_application(application.id, %{"decision" => "approve"}, reviewer.id)

    assert Repo.get!(VerificationApplication, application.id).status == "approved"
    assert Repo.aggregate(VerificationReview, :count, :id) == 0
  end

  defp latest_activity_event!(driver_id) do
    Repo.one!(
      from e in DriverActivityEvent,
        where: e.driver_id == ^driver_id,
        order_by: [desc: e.inserted_at],
        limit: 1
    )
  end
end
