defmodule Liddr.Verification.VerificationRequirement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "verification_requirements" do
    field :document_type, :string
    field :label, :string
    field :required, :boolean
    field :requires_expiry, :boolean
    field :is_active, :boolean
    field :display_order, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(requirement, attrs) do
    requirement
    |> cast(attrs, [
      :document_type,
      :label,
      :required,
      :requires_expiry,
      :is_active,
      :display_order
    ])
    |> validate_required([:document_type, :label, :required, :requires_expiry, :is_active])
    |> validate_number(:display_order, greater_than_or_equal_to: 0)
    |> unique_constraint(:document_type)
  end
end
