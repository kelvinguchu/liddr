defmodule LiddrWeb.VerificationOpsController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Verification
  alias LiddrWeb.Idempotency
  alias LiddrWeb.VerificationSerializer

  @error_mappings %{
    application_not_found:
      {:not_found, "APPLICATION_NOT_FOUND", "Verification application not found"},
    document_not_found: {:not_found, "DOCUMENT_NOT_FOUND", "Verification document not found"},
    driver_profile_not_found:
      {:not_found, "DRIVER_PROFILE_NOT_FOUND", "Driver profile not found"},
    invalid_review_decision:
      {:unprocessable_entity, "INVALID_REVIEW_DECISION",
       "Decision must be one of: approve, reject, request_resubmission, suspend"},
    invalid_document_review_decision:
      {:unprocessable_entity, "INVALID_DOCUMENT_REVIEW_DECISION",
       "Decision must be one of: approve, reject"},
    invalid_document_ids:
      {:unprocessable_entity, "INVALID_DOCUMENT_IDS",
       "document_ids must be a non-empty array of positive integer IDs"},
    application_not_reviewable:
      {:unprocessable_entity, "APPLICATION_NOT_REVIEWABLE",
       "Application cannot be reviewed in its current state"},
    document_not_reviewable:
      {:unprocessable_entity, "DOCUMENT_NOT_REVIEWABLE",
       "Document cannot be reviewed in its current state"},
    document_not_scanned_clean:
      {:unprocessable_entity, "DOCUMENT_NOT_SCANNED_CLEAN",
       "Document must pass malware scan before review"}
  }

  def list_applications(conn, params) do
    applications =
      Verification.list_applications(params)
      |> Enum.map(&VerificationSerializer.application/1)

    json(conn, %{data: %{applications: applications}})
  end

  def list_documents(conn, params) do
    documents =
      Verification.list_documents(params)
      |> Enum.map(&VerificationSerializer.document/1)

    json(conn, %{data: %{documents: documents}})
  end

  def review_application(conn, %{"id" => application_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.verification.application.review:#{application_id}",
      params,
      fn ->
        case Verification.review_application(application_id, params, reviewer_user_id) do
          {:ok, payload} ->
            {:ok, 201, %{data: VerificationSerializer.review_application(payload)}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def review_document(conn, %{"id" => document_id} = params) do
    reviewer_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ops.verification.document.review:#{document_id}",
      params,
      fn ->
        case Verification.review_document(document_id, params, reviewer_user_id) do
          {:ok, payload} ->
            {:ok, 201, %{data: VerificationSerializer.review_document(payload)}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def review_documents_bulk(conn, params) do
    reviewer_user_id = conn.assigns.current_user.id
    document_ids = Map.get(params, "document_ids")

    Idempotency.execute(
      conn,
      "ops.verification.document.review_bulk",
      params,
      fn ->
        case Verification.review_documents_bulk(document_ids, params, reviewer_user_id) do
          {:ok, results} ->
            {:ok, 201, %{data: VerificationSerializer.review_bulk(results)}}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &render_error/2
    )
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
          "VERIFICATION_REVIEW_ERROR",
          "Unable to process verification review"
        )
    end
  end

  defp render_error(conn, _unknown) do
    error_response(
      conn,
      :unprocessable_entity,
      "VERIFICATION_REVIEW_ERROR",
      "Unable to process verification review"
    )
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
