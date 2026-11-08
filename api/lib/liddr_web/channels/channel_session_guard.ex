defmodule LiddrWeb.ChannelSessionGuard do
  @moduledoc false

  alias Liddr.Auth

  @default_interval_ms 60_000

  def active?(socket), do: Auth.session_active?(socket.assigns[:current_session_id])

  def start(socket) do
    schedule_revalidation()
    socket
  end

  def revalidate(socket) do
    if active?(socket) do
      schedule_revalidation()
      {:noreply, socket}
    else
      socket.endpoint.broadcast(socket.id, "disconnect", %{})
      {:stop, :normal, socket}
    end
  end

  defp schedule_revalidation do
    Process.send_after(self(), :revalidate_session, interval_ms())
  end

  defp interval_ms do
    interval_ms =
      Application.get_env(:liddr, __MODULE__, [])
      |> Keyword.get(:interval_ms, @default_interval_ms)

    interval_ms + :rand.uniform(max(div(interval_ms, 10), 1))
  end
end
