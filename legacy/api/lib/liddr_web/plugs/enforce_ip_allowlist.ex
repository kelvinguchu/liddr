defmodule LiddrWeb.Plugs.EnforceIpAllowlist do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Security.Policy

  def init(opts), do: opts

  def call(conn, opts) do
    env_key = Keyword.fetch!(opts, :env_key)
    scope = Keyword.get(opts, :scope, env_key)

    case Policy.enforce_ip_allowlist(conn, env_key, scope) do
      :ok ->
        conn

      {:error, :ip_not_allowed} ->
        deny(conn, "IP_NOT_ALLOWED", "Request IP is not allowed for this endpoint")

      {:error, :client_ip_unresolved} ->
        deny(conn, "CLIENT_IP_UNRESOLVED", "Unable to determine request IP address")
    end
  end

  defp deny(conn, code, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: code, message: message}})
    |> halt()
  end
end
