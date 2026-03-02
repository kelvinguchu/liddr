defmodule Liddr.Authz do
  import Ecto.Query

  alias Liddr.Accounts.UserRole
  alias Liddr.Repo

  def list_active_roles(user_id) do
    Repo.all(
      from ur in UserRole,
        where: ur.user_id == ^user_id and is_nil(ur.revoked_at),
        select: ur.role
    )
  end

  def has_any_role?(user_id, allowed_roles) when is_list(allowed_roles) do
    Repo.exists?(
      from ur in UserRole,
        where:
          ur.user_id == ^user_id and is_nil(ur.revoked_at) and
            ur.role in ^allowed_roles
    )
  end
end
