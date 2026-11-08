defmodule LiddrWeb.DriverChannel do
  use LiddrWeb, :channel

  @impl true
  def join("driver:" <> driver_id, _payload, socket) do
    with {:ok, parsed_driver_id} <- parse_positive_integer(driver_id),
         true <- driver_role?(socket),
         true <- socket.assigns.current_user.id == parsed_driver_id do
      {:ok, %{driver_id: parsed_driver_id}, socket}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "forbidden"}}

  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported"}}, socket}

  defp driver_role?(socket) do
    socket.assigns
    |> Map.get(:current_roles, [])
    |> Enum.member?("driver")
  end

  defp parse_positive_integer(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end
end
