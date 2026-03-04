defmodule LiddrWeb.RideIntegrityController do
  use LiddrWeb, :controller

  alias Liddr.Rides

  def me(conn, params) do
    user = conn.assigns.current_user
    roles = conn.assigns[:current_roles] || []

    case Rides.integrity_self_view(user.id, roles, params) do
      {:ok, payload} ->
        json(conn, %{data: payload})

      {:error, :user_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "USER_NOT_FOUND", message: "User not found"}})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "RIDE_INTEGRITY_ERROR",
            message: "Unable to fetch ride integrity snapshot"
          }
        })
    end
  end
end
