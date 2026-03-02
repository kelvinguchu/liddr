defmodule Liddr.Verification.Documents do
  alias Liddr.Verification.Documents.Query
  alias Liddr.Verification.Documents.Review

  def list_documents(attrs \\ %{}), do: Query.list_documents(attrs)

  def review_document(document_id, attrs, reviewer_user_id),
    do: Review.review_document(document_id, attrs, reviewer_user_id)

  def review_documents_bulk(document_ids, attrs, reviewer_user_id),
    do: Review.review_documents_bulk(document_ids, attrs, reviewer_user_id)
end
