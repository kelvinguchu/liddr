defmodule LiddrWeb.VerificationOpsIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Verification.VerificationDocument
  alias Liddr.Verification.VerificationReview
  alias Liddr.VerificationFixtures
  alias LiddrWeb.AuthFixtures

  setup do
    previous_security_mode = System.get_env("SECURITY_MODE")
    previous_ops_ip_allowlist = System.get_env("OPS_IP_ALLOWLIST")

    System.put_env("SECURITY_MODE", "observe")
    System.delete_env("OPS_IP_ALLOWLIST")

    on_exit(fn ->
      restore_env("SECURITY_MODE", previous_security_mode)
      restore_env("OPS_IP_ALLOWLIST", previous_ops_ip_allowlist)
    end)

    :ok
  end

  test "POST /api/moderation/verification/documents/:id/reviews replays for identical key", %{
    conn: _conn
  } do
    %{auth_conn: ops_conn, user_id: reviewer_user_id} =
      AuthFixtures.authenticate_with_role!("ops")

    step_up_token = AuthFixtures.issue_step_up_token!(ops_conn)
    ops_conn = put_req_header(ops_conn, "x-step-up-token", step_up_token)

    {_driver, application, document} =
      VerificationFixtures.create_driver_application_and_document!(
        account_status: "pending",
        verification_status: "pending",
        application_status: "under_review",
        document_status: "pending_review"
      )

    key = "ops-verification-doc-review-#{System.unique_integer([:positive])}"

    first =
      ops_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/verification/documents/#{document.id}/reviews", %{
        "decision" => "approve",
        "reason" => "Document is valid"
      })
      |> json_response(201)

    second =
      ops_conn
      |> recycle()
      |> put_req_header("x-step-up-token", step_up_token)
      |> put_req_header("idempotency-key", key)
      |> post("/api/moderation/verification/documents/#{document.id}/reviews", %{
        "decision" => "approve",
        "reason" => "Document is valid"
      })
      |> json_response(201)

    assert first == second
    assert Repo.get!(VerificationDocument, document.id).status == "validated"

    assert Repo.aggregate(
             from(r in VerificationReview,
               where:
                 r.application_id == ^application.id and r.reviewer_user_id == ^reviewer_user_id
             ),
             :count,
             :id
           ) == 1
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
