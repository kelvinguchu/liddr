defmodule Liddr.Verification.VerificationApplication do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending under_review approved rejected resubmission_required suspended)
  @providers ~w(internal sumsub idenfy)

  schema "verification_applications" do
    field :status, :string
    field :provider, :string
    field :provider_reference, :string
    field :submitted_at, :utc_datetime_usec
    field :decided_at, :utc_datetime_usec
    field :decision_reason, :string

    field :driver_id, :id

    belongs_to :driver, Liddr.Accounts.Driver,
      define_field: false,
      foreign_key: :driver_id,
      references: :user_id

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(application, attrs) do
    application
    |> cast(attrs, [
      :driver_id,
      :status,
      :provider,
      :provider_reference,
      :submitted_at,
      :decided_at,
      :decision_reason
    ])
    |> validate_required([:driver_id, :status, :provider])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, @providers)
    |> foreign_key_constraint(:driver_id)
    |> check_constraint(:status, name: :verification_applications_status_valid)
    |> check_constraint(:provider, name: :verification_applications_provider_valid)
  end
end
