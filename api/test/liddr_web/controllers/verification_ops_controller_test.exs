defmodule LiddrWeb.VerificationOpsControllerTest do
  use LiddrWeb.ConnCase, async: true

  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures
  alias Liddr.Verification.VerificationApplication
  alias Liddr.Verification.VerificationDocument

  test "GET /api/moderation/verification/applications forbids non ops/admin", %{conn: _conn} do
    rider_conn = AuthFixtures.authenticate_with_role!("rider") |> Map.fetch!(:auth_conn)

    conn = get(rider_conn, "/api/moderation/verification/applications")

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "GET /api/moderation/verification/applications lists and filters", %{conn: _conn} do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {_driver_one, _app_one} = create_driver_and_application!("pending")
    {_driver_two, _app_two} = create_driver_and_application!("approved")

    conn = get(ops_conn, "/api/moderation/verification/applications?status=pending")

    assert %{"data" => %{"applications" => applications}} = json_response(conn, 200)
    assert length(applications) == 1
    assert hd(applications)["status"] == "pending"
  end

  test "GET /api/moderation/verification/documents lists, filters, paginates and sorts", %{
    conn: _conn
  } do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {driver, application, _document} = create_driver_application_and_document!("pending_review")

    _second_document =
      create_document_for_application!(
        driver.user_id,
        application.id,
        "pending_review",
        "national_id_front"
      )

    _validated_document =
      create_document_for_application!(
        driver.user_id,
        application.id,
        "validated",
        "drivers_licence"
      )

    conn =
      get(
        ops_conn,
        "/api/moderation/verification/documents?status=pending_review&sort_by=document_type&sort_order=asc&per_page=1&page=2"
      )

    assert %{"data" => %{"documents" => documents}} = json_response(conn, 200)
    assert length(documents) == 1
    assert hd(documents)["status"] == "pending_review"
    assert hd(documents)["document_type"] == "national_id_front"
  end

  test "POST /api/moderation/verification/applications/:id/reviews approve updates driver and logs event",
       %{conn: _conn} do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {driver, application} = create_driver_and_application!("under_review")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/applications/#{application.id}/reviews",
        %{
          "decision" => "approve",
          "reason" => "All required docs validated."
        }
      )

    assert %{
             "data" => %{
               "application" => %{"status" => "approved"},
               "review" => %{"decision" => "approve"},
               "driver" => %{
                 "verification_status" => "approved",
                 "account_status" => "active"
               }
             }
           } = json_response(conn, 201)

    updated_application = Repo.get!(VerificationApplication, application.id)
    assert updated_application.status == "approved"

    updated_driver = Repo.get!(Driver, driver.user_id)
    assert updated_driver.verification_status == "approved"

    event =
      Repo.one(
        from e in DriverActivityEvent,
          where: e.driver_id == ^driver.user_id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

    assert event.event_type == "verification_updated"
    assert event.reason_code == "approve"
    assert event.new_value == "approved"
  end

  test "POST /api/moderation/verification/applications/:id/reviews rejects invalid decision", %{
    conn: _conn
  } do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {_driver, application} = create_driver_and_application!("pending")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/applications/#{application.id}/reviews",
        %{
          "decision" => "invalid_decision"
        }
      )

    assert %{"error" => %{"code" => "INVALID_REVIEW_DECISION"}} = json_response(conn, 422)
  end

  test "POST /api/moderation/verification/documents/:id/reviews approve validates document", %{
    conn: _conn
  } do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {_driver, _application, document} = create_driver_application_and_document!("pending_review")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/documents/#{document.id}/reviews",
        %{
          "decision" => "approve",
          "reason" => "Document is valid"
        }
      )

    assert %{
             "data" => %{
               "document" => %{"id" => document_id, "status" => "validated"},
               "review" => %{"decision" => "approve"}
             }
           } = json_response(conn, 201)

    assert document_id == document.id

    updated_document = Repo.get!(VerificationDocument, document.id)
    assert updated_document.status == "validated"
    assert not is_nil(updated_document.reviewed_at)
  end

  test "POST /api/moderation/verification/documents/:id/reviews reject marks resubmission required",
       %{
         conn: _conn
       } do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {driver, application, document} = create_driver_application_and_document!("pending_review")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/documents/#{document.id}/reviews",
        %{
          "decision" => "reject",
          "reason" => "Image is blurry"
        }
      )

    assert %{
             "data" => %{
               "document" => %{"status" => "rejected", "rejection_reason" => "Image is blurry"},
               "application" => %{"status" => "resubmission_required"},
               "driver" => %{"verification_status" => "pending"}
             }
           } = json_response(conn, 201)

    updated_application = Repo.get!(VerificationApplication, application.id)
    assert updated_application.status == "resubmission_required"

    updated_document = Repo.get!(VerificationDocument, document.id)
    assert updated_document.status == "rejected"

    updated_driver = Repo.get!(Driver, driver.user_id)
    assert updated_driver.verification_status == "pending"

    event =
      Repo.one(
        from e in DriverActivityEvent,
          where: e.driver_id == ^driver.user_id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

    assert event.reason_code == "document_reject"
    assert event.new_value == "rejected"
  end

  test "POST /api/moderation/verification/documents/reviews/bulk approves all documents atomically",
       %{conn: _conn} do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)

    {_driver, _application, document_one} =
      create_driver_application_and_document!("pending_review")

    {_driver_two, _application_two, document_two} =
      create_driver_application_and_document!("pending_review")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/documents/reviews/bulk",
        %{
          "document_ids" => [document_one.id, document_two.id],
          "decision" => "approve",
          "reason" => "Bulk approved"
        }
      )

    assert %{"data" => %{"count" => 2, "results" => results}} = json_response(conn, 201)
    assert length(results) == 2
    assert Enum.all?(results, fn r -> get_in(r, ["document", "status"]) == "validated" end)

    assert Repo.get!(VerificationDocument, document_one.id).status == "validated"
    assert Repo.get!(VerificationDocument, document_two.id).status == "validated"
  end

  test "POST /api/moderation/verification/documents/reviews/bulk rolls back if any document fails",
       %{conn: _conn} do
    ops_conn = AuthFixtures.authenticate_with_role!("ops") |> Map.fetch!(:auth_conn)
    {_driver, _application, document} = create_driver_application_and_document!("pending_review")

    conn =
      post(
        ops_conn,
        "/api/moderation/verification/documents/reviews/bulk",
        %{
          "document_ids" => [document.id, -1],
          "decision" => "approve",
          "reason" => "Should fail"
        }
      )

    assert %{"error" => %{"code" => "INVALID_DOCUMENT_IDS"}} = json_response(conn, 422)
    assert Repo.get!(VerificationDocument, document.id).status == "pending_review"
  end

  defp create_driver_and_application!(status) do
    VerificationFixtures.create_driver_and_application!(
      account_status: "pending",
      verification_status: "pending",
      application_status: status
    )
  end

  defp create_driver_application_and_document!(document_status) do
    {driver, application, document} =
      VerificationFixtures.create_driver_application_and_document!(
        account_status: "pending",
        verification_status: "pending",
        application_status: "under_review",
        document_status: document_status
      )

    {driver, application, document}
  end

  defp create_document_for_application!(
         driver_id,
         application_id,
         status,
         document_type
       ) do
    VerificationFixtures.create_verification_document!(
      driver_id,
      application_id,
      document_type: document_type,
      status: status
    )
  end
end
