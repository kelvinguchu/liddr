defmodule LiddrWeb.RequestMeta do
  @moduledoc false

  alias Liddr.Security.Policy

  def auth(conn) do
    %{
      ip: Policy.request_client_ip(conn),
      device: header(conn, "x-device-id"),
      user_agent: header(conn, "user-agent")
    }
  end

  def security(conn) do
    %{
      ip: Policy.request_client_ip(conn),
      device: header(conn, "x-device-id")
    }
  end

  defp header(conn, key) do
    conn
    |> Plug.Conn.get_req_header(key)
    |> List.first()
    |> normalize_text()
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
