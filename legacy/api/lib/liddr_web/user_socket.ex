defmodule LiddrWeb.UserSocket do
  use Phoenix.Socket

  alias Liddr.Auth
  alias Liddr.Authz

  channel "driver:*", LiddrWeb.DriverChannel
  channel "ride:*", LiddrWeb.RideChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Auth.authenticate_access_token(String.trim(token), %{}) do
      {:ok, payload} ->
        roles = Authz.list_active_roles(payload.user.id)

        {:ok,
         socket
         |> assign(:current_user, payload.user)
         |> assign(:current_roles, roles)
         |> assign(:current_session_id, payload.session_id)
         |> assign(:current_auth_method, payload.auth_method)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> "users_socket:#{id}"
      _ -> nil
    end
  end
end
