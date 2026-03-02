defmodule Liddr.Moderation.Query do
  import Ecto.Query

  def maybe_filter_equals(query, _field, value) when value in [nil, ""], do: query

  def maybe_filter_equals(query, field, value) do
    from q in query, where: field(q, ^field) == ^value
  end

  def apply_sort(query, attrs, allowed_fields, default_field) do
    sort_by =
      attrs
      |> get_value(:sort_by)
      |> normalize_text()

    sort_field = Map.get(allowed_fields, sort_by, default_field)
    sort_order = parse_sort_order(get_value(attrs, :sort_order))

    from q in query,
      order_by: [{^sort_order, field(q, ^sort_field)}, desc: q.id]
  end

  def apply_pagination(query, attrs) do
    per_page =
      attrs
      |> get_value(:per_page)
      |> parse_integer()
      |> case do
        n when is_integer(n) and n > 0 and n <= 200 ->
          n

        _ ->
          attrs
          |> get_value(:limit)
          |> parse_integer()
          |> case do
            n when is_integer(n) and n > 0 and n <= 200 -> n
            _ -> 100
          end
      end

    page =
      attrs
      |> get_value(:page)
      |> parse_integer()
      |> case do
        n when is_integer(n) and n > 0 -> n
        _ -> 1
      end

    offset_value = (page - 1) * per_page
    from q in query, limit: ^per_page, offset: ^offset_value
  end

  def parse_integer(nil), do: nil
  def parse_integer(value) when is_integer(value), do: value

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_integer(_), do: nil

  def get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  def get_value(_attrs, _key), do: nil

  def normalize_text(nil), do: nil

  def normalize_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_text(value), do: value |> to_string() |> normalize_text()

  def normalize_applies_to("driver"), do: "driver"
  def normalize_applies_to("passenger"), do: "passenger"
  def normalize_applies_to(_value), do: nil

  def unwrap_transaction_result({:ok, payload}), do: {:ok, payload}
  def unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp parse_sort_order(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "asc" -> :asc
      _ -> :desc
    end
  end

  defp parse_sort_order(_value), do: :desc
end
