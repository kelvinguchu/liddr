defmodule LiddrWeb.Plugs.RequireTotpEnrollment do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Auth.TotpEnrollment

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: user_id} ->
        if TotpEnrollment.active_identity(user_id) do
          conn
        else
          render_error(conn)
        end

      _ ->
        render_error(conn)
    end
  end

  defp render_error(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "OPS_MFA_ENROLLMENT_REQUIRED",
        message: "Ops/admin access requires TOTP enrollment before this endpoint can be used"
      }
    })
    |> halt()
  end
end
