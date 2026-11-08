defmodule LiddrWeb.HealthController do
  use LiddrWeb, :controller

  def show(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
