defmodule Liddr.Verification.VerificationReview do
  use Ecto.Schema
  import Ecto.Changeset

  @decisions ~w(approve reject request_resubmission suspend)

  schema "verification_reviews" do
    field :decision, :string
    field :reason, :string
    field :decided_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :application, Liddr.Verification.VerificationApplication
    field :driver_id, :id

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    belongs_to :reviewer_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(review, attrs) do
    review
    |> cast(attrs, [
      :application_id,
      :driver_id,
      :reviewer_user_id,
      :decision,
      :reason,
      :decided_at,
      :metadata
    ])
    |> validate_required([:application_id, :driver_id, :reviewer_user_id, :decision, :decided_at])
    |> validate_inclusion(:decision, @decisions)
    |> foreign_key_constraint(:application_id)
    |> foreign_key_constraint(:driver_id)
    |> foreign_key_constraint(:reviewer_user_id)
    |> check_constraint(:decision, name: :verification_reviews_decision_valid)
  end
end
