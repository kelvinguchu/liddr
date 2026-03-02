defmodule LiddrWeb.Plugs.RequireAnyRole do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Authz

  def init(opts), do: opts

  def call(conn, opts) do
    allowed_roles = Keyword.get(opts, :roles, [])
    current_user = conn.assigns[:current_user]

    cond do
      is_nil(current_user) ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "AUTH_REQUIRED", message: "Authentication is required"}})
        |> halt()

      Authz.has_any_role?(current_user.id, allowed_roles) ->
        roles = Authz.list_active_roles(current_user.id)
        assign(conn, :current_roles, roles)

      true ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            code: "FORBIDDEN_ROLE",
            message: "You do not have permission for this action"
          }
        })
        |> halt()
    end
  end
end
