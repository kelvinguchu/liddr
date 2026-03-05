defmodule Liddr.Rides.ProhibitedItems do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.ProhibitedItem

  def evaluate(item_description) when is_binary(item_description) do
    description = normalize_text(item_description)

    matches =
      from(item in ProhibitedItem,
        where: item.is_active == true
      )
      |> Repo.all()
      |> Enum.filter(&description_match?(description, &1.keyword))
      |> Enum.map(&match_payload/1)

    blocked = Enum.filter(matches, &(&1.severity == "block"))
    warned = Enum.filter(matches, &(&1.severity == "warn"))

    if blocked == [] do
      {:ok, %{warnings: warned}}
    else
      {:error, {:prohibited_item_blocked, %{matches: blocked, warnings: warned}}}
    end
  end

  def evaluate(_item_description), do: {:ok, %{warnings: []}}

  defp description_match?(description, keyword) when is_binary(keyword) do
    normalized_keyword = normalize_text(keyword)
    normalized_keyword != "" and String.contains?(description, normalized_keyword)
  end

  defp description_match?(_description, _keyword), do: false

  defp match_payload(%ProhibitedItem{} = item) do
    %{
      keyword: item.keyword,
      severity: item.severity,
      message: item.message
    }
  end

  defp normalize_text(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end
end
