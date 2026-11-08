defmodule Liddr.Rides.PushClient.Noop do
  @moduledoc false

  @behaviour Liddr.Rides.PushClient

  @impl Liddr.Rides.PushClient
  def send_ride_notification(_payload), do: {:error, :push_not_configured}
end
