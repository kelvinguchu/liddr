defmodule Liddr.Moderation.ReportCategory do
  use Ecto.Schema
  import Ecto.Changeset

  @applies_to_values ~w(driver passenger both)
  @recommended_actions ~w(review warn temporary_suspension permanent_ban)

  schema "report_categories" do
    field :slug, :string
    field :label, :string
    field :description, :string
    field :applies_to, :string
    field :severity_level_default, :integer
    field :recommended_action, :string
    field :requires_immediate_attention, :boolean
    field :is_active, :boolean
    field :display_order, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(report_category, attrs) do
    report_category
    |> cast(attrs, [
      :slug,
      :label,
      :description,
      :applies_to,
      :severity_level_default,
      :recommended_action,
      :requires_immediate_attention,
      :is_active,
      :display_order
    ])
    |> validate_required([
      :slug,
      :label,
      :applies_to,
      :severity_level_default,
      :recommended_action
    ])
    |> validate_inclusion(:applies_to, @applies_to_values)
    |> validate_inclusion(:recommended_action, @recommended_actions)
    |> validate_number(:severity_level_default,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 5
    )
    |> validate_number(:display_order, greater_than_or_equal_to: 0)
    |> unique_constraint(:slug)
  end
end
