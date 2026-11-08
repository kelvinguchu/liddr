defmodule Liddr.Verification.Documents.Query do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationDocument

  @document_sort_fields %{
    "inserted_at" => :inserted_at,
    "reviewed_at" => :reviewed_at,
    "status" => :status,
    "document_type" => :document_type
  }

  def list_documents(attrs \\ %{}) do
    query = from(d in VerificationDocument)

    query
    |> Shared.maybe_filter_equals(:status, Shared.get_value(attrs, :status))
    |> Shared.maybe_filter_equals(:document_type, Shared.get_value(attrs, :document_type))
    |> Shared.maybe_filter_equals(:capture_source, Shared.get_value(attrs, :capture_source))
    |> Shared.maybe_filter_equals(
      :driver_id,
      Shared.parse_integer(Shared.get_value(attrs, :driver_id))
    )
    |> Shared.maybe_filter_equals(
      :application_id,
      Shared.parse_integer(Shared.get_value(attrs, :application_id))
    )
    |> Shared.apply_sort(attrs, @document_sort_fields, :inserted_at)
    |> Shared.apply_pagination(attrs)
    |> Repo.all()
  end
end
