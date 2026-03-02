defmodule Liddr.Verification.Documents.ReviewInput do
  alias Liddr.Verification.Shared

  @document_review_decisions ~w(approve reject)

  def fetch_document_review_decision(attrs) do
    decision =
      attrs
      |> Shared.get_value(:decision)
      |> Shared.normalize_text()

    if decision in @document_review_decisions do
      {:ok, decision}
    else
      {:error, :invalid_document_review_decision}
    end
  end

  def parse_document_id(document_id) do
    case Shared.parse_integer(document_id) do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, :document_not_found}
    end
  end

  def parse_document_ids(document_ids) when is_list(document_ids) do
    parsed_ids =
      document_ids
      |> Enum.map(&Shared.parse_integer/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()

    cond do
      parsed_ids == [] ->
        {:error, :invalid_document_ids}

      length(parsed_ids) != length(document_ids) ->
        {:error, :invalid_document_ids}

      true ->
        {:ok, parsed_ids}
    end
  end

  def parse_document_ids(_), do: {:error, :invalid_document_ids}
end
