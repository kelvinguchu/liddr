defmodule Liddr.Verification.Documents.Review do
  alias Liddr.Repo
  alias Liddr.Verification.Documents.ReviewInput
  alias Liddr.Verification.Documents.ReviewWorkflow
  alias Liddr.Verification.Shared

  def review_document(document_id, attrs, reviewer_user_id) do
    with {:ok, decision} <- ReviewInput.fetch_document_review_decision(attrs),
         {:ok, parsed_document_id} <- ReviewInput.parse_document_id(document_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        ReviewWorkflow.review_document_locked(
          parsed_document_id,
          decision,
          attrs,
          reviewer_user_id,
          now
        )
      end)
      |> Shared.unwrap_transaction_result()
    end
  end

  def review_documents_bulk(document_ids, attrs, reviewer_user_id) do
    with {:ok, decision} <- ReviewInput.fetch_document_review_decision(attrs),
         {:ok, parsed_document_ids} <- ReviewInput.parse_document_ids(document_ids) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        Enum.reduce(parsed_document_ids, [], fn document_id, acc ->
          result =
            ReviewWorkflow.review_document_locked(
              document_id,
              decision,
              attrs,
              reviewer_user_id,
              now
            )

          [result | acc]
        end)
        |> Enum.reverse()
      end)
      |> case do
        {:ok, results} -> {:ok, results}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
