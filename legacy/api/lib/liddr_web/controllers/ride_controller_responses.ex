defmodule LiddrWeb.RideControllerResponses do
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  alias LiddrWeb.RideControllerErrors
  alias LiddrWeb.RideSerializer

  def with_rider(conn, params, action, status, payload_type) do
    with_user(conn, conn.assigns.current_user.id, params, action, status, payload_type)
  end

  def with_driver(conn, params, action, status, payload_type) do
    with_user(conn, conn.assigns.current_user.id, params, action, status, payload_type)
  end

  defp with_user(conn, user_id, params, action, status, payload_type) do
    case action.(user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(status)
        |> json(%{data: serialize_payload(payload_type, payload)})

      {:error, reason} ->
        RideControllerErrors.render(conn, reason)
    end
  end

  defp serialize_payload(:quote, quote), do: %{quote: RideSerializer.quote_payload(quote)}
  defp serialize_payload(:request, payload), do: RideSerializer.request_payload(payload)
  defp serialize_payload(:history, rides), do: RideSerializer.history_payload(rides)

  defp serialize_payload(:driver_offers, offers) do
    %{offers: Enum.map(offers, &RideSerializer.driver_offer_payload/1)}
  end
end
