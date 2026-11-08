defmodule LiddrWeb.RideChannel do
  use LiddrWeb, :channel

  alias Liddr.Rides
  alias LiddrWeb.RideSerializer

  @impl true
  def join("ride:" <> ride_id, payload, socket) do
    user_id = socket.assigns.current_user.id
    join_params = normalize_join_params(payload)

    with {:ok, %{ride: ride, events: events, next_since: next_since}} <-
           Rides.list_events_for_user(user_id, ride_id, join_params) do
      {:ok,
       %{
         ride_id: ride.id,
         ride: RideSerializer.ride_payload(ride),
         events: Enum.map(events, &RideSerializer.event_payload/1),
         next_since: next_since
       }, assign(socket, :ride_id, ride.id)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "forbidden"}}

  @impl true
  def handle_in("timeline.sync", payload, socket) do
    user_id = socket.assigns.current_user.id
    ride_id = socket.assigns.ride_id
    sync_params = normalize_join_params(payload)

    case Rides.list_events_for_user(user_id, ride_id, sync_params) do
      {:ok, %{events: events, next_since: next_since}} ->
        {:reply,
         {:ok,
          %{
            ride_id: ride_id,
            events: Enum.map(events, &RideSerializer.event_payload/1),
            next_since: next_since
          }}, socket}

      {:error, _reason} ->
        {:reply, {:error, %{reason: "forbidden"}}, socket}
    end
  end

  @impl true
  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unsupported"}}, socket}

  defp normalize_join_params(%{} = payload) do
    %{
      "since" => Map.get(payload, "since") || Map.get(payload, :since),
      "limit" => Map.get(payload, "limit") || Map.get(payload, :limit)
    }
  end

  defp normalize_join_params(_payload), do: %{}
end
