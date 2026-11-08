defmodule LiddrWeb.RideChannel do
  use LiddrWeb, :channel

  alias Liddr.Rides
  alias Liddr.Rides.DriverTracking
  alias LiddrWeb.ChannelSessionGuard
  alias LiddrWeb.RideSerializer

  @driver_location_event DriverTracking.event()

  intercept [@driver_location_event]

  @impl true
  def join("ride:" <> ride_id, payload, socket) do
    user_id = socket.assigns.current_user.id
    join_params = normalize_join_params(payload)

    with true <- ChannelSessionGuard.active?(socket),
         {:ok, %{ride: ride, events: events, next_since: next_since}} <-
           Rides.list_events_for_user(user_id, ride_id, join_params) do
      {:ok,
       %{
         ride_id: ride.id,
         ride: RideSerializer.ride_payload(ride),
         events: Enum.map(events, &RideSerializer.event_payload/1),
         next_since: next_since,
         driver_location: DriverTracking.latest_for_user(ride, user_id)
       }, socket |> assign(:ride_id, ride.id) |> ChannelSessionGuard.start()}
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

  @impl true
  def handle_info(:revalidate_session, socket), do: ChannelSessionGuard.revalidate(socket)

  @impl true
  def handle_out(@driver_location_event, %{visible_user_ids: user_ids} = payload, socket) do
    if socket.assigns.current_user.id in user_ids do
      push(socket, @driver_location_event, Map.delete(payload, :visible_user_ids))
    end

    {:noreply, socket}
  end

  defp normalize_join_params(%{} = payload) do
    %{
      "since" => Map.get(payload, "since") || Map.get(payload, :since),
      "limit" => Map.get(payload, "limit") || Map.get(payload, :limit)
    }
  end

  defp normalize_join_params(_payload), do: %{}
end
