defmodule Liddr.Rides.ProhibitedItem do
  use Ecto.Schema
  import Ecto.Changeset

  @severities ~w(warn block)

  schema "prohibited_items" do
    field :keyword, :string
    field :severity, :string, default: "block"
    field :message, :string
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(item, attrs) do
    item
    |> cast(attrs, [:keyword, :severity, :message, :is_active])
    |> validate_required([:keyword, :severity])
    |> update_change(:keyword, &normalize_keyword/1)
    |> validate_length(:keyword, min: 2, max: 120)
    |> validate_inclusion(:severity, @severities)
    |> unique_constraint(:keyword)
  end

  defp normalize_keyword(nil), do: nil

  defp normalize_keyword(keyword) do
    keyword
    |> String.trim()
    |> String.downcase()
  end
end
