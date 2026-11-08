defmodule Liddr.Verification.Applications.Query do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Verification.Shared
  alias Liddr.Verification.VerificationApplication

  @application_sort_fields %{
    "inserted_at" => :inserted_at,
    "submitted_at" => :submitted_at,
    "status" => :status
  }

  def list_applications(attrs \\ %{}) do
    query = from(a in VerificationApplication)

    query
    |> Shared.maybe_filter_equals(:status, Shared.get_value(attrs, :status))
    |> Shared.maybe_filter_equals(
      :driver_id,
      Shared.parse_integer(Shared.get_value(attrs, :driver_id))
    )
    |> Shared.maybe_filter_equals(:provider, Shared.get_value(attrs, :provider))
    |> Shared.apply_sort(attrs, @application_sort_fields, :inserted_at)
    |> Shared.apply_pagination(attrs)
    |> Repo.all()
  end
end
