defmodule Liddr.Accounts.UserRole do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(rider driver ops admin)

  schema "user_roles" do
    field :role, :string
    field :granted_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, Liddr.Accounts.User
    belongs_to :granted_by_user, Liddr.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def create_changeset(user_role, attrs) do
    user_role
    |> cast(attrs, [:user_id, :role, :granted_at, :granted_by_user_id, :metadata, :revoked_at])
    |> validate_required([:user_id, :role, :granted_at])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:role, name: :user_roles_one_active_role_per_user)
  end
end
