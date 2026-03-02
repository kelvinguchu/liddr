defmodule LiddrWeb.Plugs.AuthenticateAccessToken do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Liddr.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- fetch_bearer_token(conn),
         {:ok, payload} <- Auth.authenticate_access_token(token, request_meta(conn)) do
      conn
      |> assign(:current_user, payload.user)
      |> assign(:current_session_id, payload.session_id)
      |> assign(:current_auth_method, payload.auth_method)
    else
      {:error, reason} ->
        conn
        |> put_status(status_for(reason))
        |> json(%{error: %{code: code_for(reason), message: message_for(reason)}})
        |> halt()
    end
  end

  defp fetch_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] ->
        parse_bearer(value)

      _ ->
        {:error, :auth_required}
    end
  end

  defp parse_bearer("Bearer " <> token) do
    if String.trim(token) == "" do
      {:error, :auth_required}
    else
      {:ok, String.trim(token)}
    end
  end

  defp parse_bearer(_), do: {:error, :auth_required}

  defp request_meta(conn) do
    %{
      ip: remote_ip_to_string(conn.remote_ip),
      device: List.first(get_req_header(conn, "x-device-id")),
      user_agent: List.first(get_req_header(conn, "user-agent"))
    }
  end

  defp remote_ip_to_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp remote_ip_to_string({a, b, c, d, e, f, g, h}),
    do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"

  defp remote_ip_to_string(_), do: nil

  defp status_for(:auth_required), do: :unauthorized
  defp status_for(:invalid_access_token), do: :unauthorized
  defp status_for(:access_token_revoked), do: :unauthorized
  defp status_for(:access_token_expired), do: :unauthorized
  defp status_for(:account_suspended), do: :forbidden
  defp status_for(:account_banned), do: :forbidden
  defp status_for(:account_deactivated), do: :forbidden
  defp status_for(:user_not_found), do: :unauthorized
  defp status_for(_), do: :unauthorized

  defp code_for(:auth_required), do: "AUTH_REQUIRED"
  defp code_for(:invalid_access_token), do: "INVALID_ACCESS_TOKEN"
  defp code_for(:access_token_revoked), do: "ACCESS_TOKEN_REVOKED"
  defp code_for(:access_token_expired), do: "ACCESS_TOKEN_EXPIRED"
  defp code_for(:account_suspended), do: "ACCOUNT_SUSPENDED"
  defp code_for(:account_banned), do: "ACCOUNT_BANNED"
  defp code_for(:account_deactivated), do: "ACCOUNT_DEACTIVATED"
  defp code_for(:user_not_found), do: "USER_NOT_FOUND"
  defp code_for(_), do: "UNAUTHORIZED"

  defp message_for(:auth_required), do: "Authorization bearer token is required"
  defp message_for(:invalid_access_token), do: "Invalid access token"
  defp message_for(:access_token_revoked), do: "Access token has been revoked"
  defp message_for(:access_token_expired), do: "Access token has expired"
  defp message_for(:account_suspended), do: "This account is currently suspended"
  defp message_for(:account_banned), do: "This account has been permanently banned"
  defp message_for(:account_deactivated), do: "This account has been deactivated"
  defp message_for(:user_not_found), do: "User not found"
  defp message_for(_), do: "Unauthorized"
end
