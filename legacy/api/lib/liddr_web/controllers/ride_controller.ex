defmodule LiddrWeb.RideController do
  use LiddrWeb, :controller

  alias Liddr.Rides
  alias LiddrWeb.Idempotency
  alias LiddrWeb.RideControllerErrors
  alias LiddrWeb.RideControllerReadActions
  alias LiddrWeb.RideControllerResponses
  alias LiddrWeb.RideSerializer
  alias LiddrWeb.RequestMeta

  def quote(conn, params),
    do: RideControllerResponses.with_rider(conn, params, &Rides.create_quote/2, 201, :quote)

  def request(conn, params) do
    rider_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.request",
      params,
      fn ->
        with :ok <-
               Rides.enforce_action_security_signals(
                 :ride_request,
                 rider_user_id,
                 RequestMeta.security(conn)
               ),
             :ok <- Rides.enforce_rider_request_rate_limit(rider_user_id),
             {:ok, payload} <- Rides.request_ride(rider_user_id, params) do
          {:ok, 201, %{data: RideSerializer.request_payload(payload)}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def rider_history(conn, params),
    do: RideControllerResponses.with_rider(conn, params, &Rides.rider_history/2, 200, :history)

  def driver_offers(conn, params),
    do:
      RideControllerResponses.with_driver(
        conn,
        params,
        &Rides.list_driver_offers/2,
        200,
        :driver_offers
      )

  def driver_history(conn, params),
    do: RideControllerResponses.with_driver(conn, params, &Rides.driver_history/2, 200, :history)

  def show(conn, %{"ride_id" => ride_id}),
    do: RideControllerReadActions.show(conn, conn.assigns.current_user.id, ride_id)

  def events(conn, %{"ride_id" => ride_id} = params),
    do: RideControllerReadActions.events(conn, conn.assigns.current_user.id, ride_id, params)

  def incidents(conn, %{"ride_id" => ride_id} = params),
    do: RideControllerReadActions.incidents(conn, conn.assigns.current_user.id, ride_id, params)

  def current_status(conn, %{"ride_id" => ride_id}),
    do: RideControllerReadActions.current_status(conn, conn.assigns.current_user.id, ride_id)

  def accept_offer(conn, %{"offer_id" => offer_id}) do
    driver_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.offer.accept:#{offer_id}",
      conn.body_params,
      fn ->
        case Rides.accept_offer(driver_user_id, offer_id) do
          {:ok, payload} -> {:ok, 200, %{data: RideSerializer.accept_payload(payload)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def reject_offer(conn, %{"offer_id" => offer_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.reject_offer(driver_user_id, offer_id) do
      {:ok, payload} -> json(conn, %{data: RideSerializer.accept_payload(payload)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def complete(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.complete:#{ride_id}",
      conn.body_params,
      fn ->
        case Rides.complete_ride(driver_user_id, ride_id, conn.body_params) do
          {:ok, ride} -> {:ok, 200, %{data: %{ride: RideSerializer.ride_payload(ride)}}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def driver_arriving(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.mark_driver_arriving(driver_user_id, ride_id) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def driver_arrived(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.mark_driver_arrived(driver_user_id, ride_id) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def start_trip(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.start:#{ride_id}",
      conn.body_params,
      fn ->
        case Rides.start_ride(driver_user_id, ride_id) do
          {:ok, ride} -> {:ok, 200, %{data: %{ride: RideSerializer.ride_payload(ride)}}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def rider_cancel(conn, %{"ride_id" => ride_id}) do
    rider_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.rider_cancel:#{ride_id}",
      conn.body_params,
      fn ->
        with :ok <-
               Rides.enforce_action_security_signals(
                 :rider_cancel,
                 rider_user_id,
                 RequestMeta.security(conn)
               ),
             :ok <- Rides.enforce_rider_cancel_rate_limit(rider_user_id),
             {:ok, ride} <- Rides.rider_cancel_ride(rider_user_id, ride_id, conn.body_params) do
          {:ok, 200, %{data: %{ride: RideSerializer.ride_payload(ride)}}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def pickup_health(conn, %{"ride_id" => ride_id}) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.pickup_health(rider_user_id, ride_id) do
      {:ok, %{ride: ride, health: health}} ->
        json(conn, %{data: %{ride: RideSerializer.ride_payload(ride), pickup_health: health}})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def reassign(conn, %{"ride_id" => ride_id}) do
    rider_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.reassign:#{ride_id}",
      conn.body_params,
      fn ->
        case Rides.request_reassign(rider_user_id, ride_id, conn.body_params) do
          {:ok, ride} -> {:ok, 200, %{data: %{ride: RideSerializer.ride_payload(ride)}}}
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def driver_cancel(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "ride.driver_cancel:#{ride_id}",
      conn.body_params,
      fn ->
        with :ok <-
               Rides.enforce_action_security_signals(
                 :driver_cancel,
                 driver_user_id,
                 RequestMeta.security(conn)
               ),
             :ok <- Rides.enforce_driver_cancel_rate_limit(driver_user_id),
             {:ok, ride} <- Rides.driver_cancel_ride(driver_user_id, ride_id, conn.body_params) do
          {:ok, 200, %{data: %{ride: RideSerializer.ride_payload(ride)}}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def rider_no_show(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    with :ok <-
           Rides.enforce_action_security_signals(
             :driver_no_show,
             driver_user_id,
             RequestMeta.security(conn)
           ),
         :ok <- Rides.enforce_driver_no_show_rate_limit(driver_user_id),
         {:ok, ride} <- Rides.mark_rider_no_show(driver_user_id, ride_id, conn.body_params) do
      json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, reason), do: RideControllerErrors.render(conn, reason)
end
