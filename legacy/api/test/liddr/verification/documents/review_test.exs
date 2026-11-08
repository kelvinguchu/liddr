defmodule Liddr.Verification.Documents.ReviewTest do
  use Liddr.DataCase, async: true

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Verification.Documents.Review
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationReview

  test "approve validates document and promotes pending application to under_review" do
    {driver, _application, document, reviewer} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "pending",
        document_status: "pending_review",
        verification_status: "pending"
      )

    assert {:ok, result} =
             Review.review_document(
               document.id,
               %{"decision" => "approve", "reason" => "Valid document"},
               reviewer.id
             )

    assert result.document.status == "validated"
    assert result.application.status == "under_review"
    assert result.driver.verification_status == "under_review"
    assert result.review.decision == "approve"
    assert result.review.metadata["document_id"] == document.id

    event = latest_activity_event!(driver.user_id)
    assert event.reason_code == "document_approve"
    assert event.previous_value == "pending_review"
    assert event.new_value == "validated"
  end

  test "reject marks document rejected and sets application resubmission_required" do
    {_driver, _application, document, reviewer} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "under_review",
        document_status: "pending_review",
        account_status: "active",
        verification_status: "under_review"
      )

    assert {:ok, result} =
             Review.review_document(
               document.id,
               %{"decision" => "reject", "reason" => "Image blurry"},
               reviewer.id
             )

    assert result.document.status == "rejected"
    assert result.document.rejection_reason == "Image blurry"
    assert result.application.status == "resubmission_required"
    assert result.driver.verification_status == "pending"
    assert result.driver.account_status == "pending"
    assert result.review.decision == "reject"
  end

  test "reject preserves suspended account_status for suspended drivers" do
    {_driver, _application, document, reviewer} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "under_review",
        document_status: "pending_review",
        account_status: "suspended",
        verification_status: "suspended"
      )

    assert {:ok, result} =
             Review.review_document(
               document.id,
               %{"decision" => "reject", "reason" => "Missing info"},
               reviewer.id
             )

    assert result.driver.account_status == "suspended"
    assert result.driver.verification_status == "pending"
  end

  test "returns document_not_reviewable when document status is already validated" do
    {_driver, _application, document, reviewer} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "under_review",
        document_status: "validated"
      )

    assert {:error, :document_not_reviewable} =
             Review.review_document(document.id, %{"decision" => "approve"}, reviewer.id)

    unchanged_document = Repo.get!(VerificationDocument, document.id)
    assert unchanged_document.status == "validated"
    assert Repo.aggregate(VerificationReview, :count, :id) == 0
  end

  test "bulk review rolls back all changes if one document is not reviewable" do
    {_driver, _application, document_one, reviewer} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "under_review",
        document_status: "pending_review"
      )

    {_driver_two, _application_two, document_two, _reviewer_two} =
      VerificationFixtures.create_driver_application_document_and_reviewer!(
        application_status: "under_review",
        document_status: "validated"
      )

    assert {:error, :document_not_reviewable} =
             Review.review_documents_bulk(
               [document_one.id, document_two.id],
               %{"decision" => "approve", "reason" => "Bulk run"},
               reviewer.id
             )

    reloaded_one = Repo.get!(VerificationDocument, document_one.id)
    reloaded_two = Repo.get!(VerificationDocument, document_two.id)
    assert reloaded_one.status == "pending_review"
    assert is_nil(reloaded_one.reviewed_at)
    assert reloaded_two.status == "validated"

    assert Repo.aggregate(VerificationReview, :count, :id) == 0
    assert Repo.aggregate(DriverActivityEvent, :count, :id) == 0
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
