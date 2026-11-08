defmodule Liddr.Idempotency.Request do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime_usec]
  @primary_key {:id, :id, autogenerate: true}

  schema "idempotency_requests" do
    field :operation, :string
    field :idempotency_key, :string
    field :request_hash, :string
    field :response_status, :integer
    field :response_body, :map
    field :completed_at, :utc_datetime_usec

    belongs_to :user, Liddr.Accounts.User

    timestamps()
  end

  def create_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:user_id, :operation, :idempotency_key, :request_hash])
    |> validate_required([:user_id, :operation, :idempotency_key, :request_hash])
    |> validate_length(:operation, min: 1, max: 120)
    |> validate_length(:idempotency_key, min: 8, max: 120)
    |> validate_length(:request_hash, is: 64)
    |> unique_constraint(
      [:user_id, :operation, :idempotency_key],
      name: :idempotency_requests_unique_user_operation_key
    )
  end

  def complete_changeset(struct, attrs) do
    struct
    |> cast(attrs, [:response_status, :response_body, :completed_at])
    |> validate_required([:response_status, :response_body, :completed_at])
  end
end
