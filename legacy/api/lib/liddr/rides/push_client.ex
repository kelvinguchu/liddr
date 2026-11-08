defmodule Liddr.Rides.PushClient do
  @moduledoc false

  @callback send_ride_notification(map()) :: :ok | {:error, term()}
end
