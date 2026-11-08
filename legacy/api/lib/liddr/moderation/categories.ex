defmodule Liddr.Moderation.Categories do
  import Ecto.Query

  alias Liddr.Moderation.Query
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo

  def list_report_categories(attrs \\ %{}) do
    applies_to =
      attrs
      |> Query.get_value(:applies_to)
      |> Query.normalize_text()
      |> Query.normalize_applies_to()

    base_query =
      from rc in ReportCategory,
        where: rc.is_active == true,
        order_by: [asc: rc.display_order, asc: rc.id]

    query =
      case applies_to do
        nil ->
          base_query

        value ->
          from rc in base_query,
            where: rc.applies_to in ["both", ^value]
      end

    Repo.all(query)
  end

  def resolve_category(attrs) do
    category_id = Query.get_value(attrs, :category_id)
    category_slug = attrs |> Query.get_value(:category_slug) |> Query.normalize_text()

    category =
      cond do
        not is_nil(category_id) ->
          Repo.get(ReportCategory, category_id)

        not is_nil(category_slug) ->
          Repo.get_by(ReportCategory, slug: category_slug)

        true ->
          nil
      end

    cond do
      is_nil(category) -> {:error, :missing_report_category}
      category.is_active != true -> {:error, :inactive_report_category}
      true -> {:ok, category}
    end
  end
end
