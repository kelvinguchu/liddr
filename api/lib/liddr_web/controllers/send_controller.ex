defmodule LiddrWeb.SendController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides
  alias LiddrWeb.Idempotency
  alias LiddrWeb.RideSerializer

  @known_errors %{
    rider_not_found: {:unprocessable_entity, "RIDER_NOT_FOUND", "Rider account was not found"},
    send_category_not_found:
      {:unprocessable_entity, "SEND_CATEGORY_NOT_FOUND", "Active send category is not configured"},
    missing_sender_name:
      {:unprocessable_entity, "MISSING_SENDER_NAME", "sender_name is required"},
    missing_sender_phone:
      {:unprocessable_entity, "MISSING_SENDER_PHONE",
       "sender_phone is required or rider account must have a phone"},
    invalid_sender_phone:
      {:unprocessable_entity, "INVALID_SENDER_PHONE", "sender_phone must be a valid Kenyan phone"},
    missing_recipient_name:
      {:unprocessable_entity, "MISSING_RECIPIENT_NAME", "recipient_name is required"},
    missing_recipient_phone:
      {:unprocessable_entity, "MISSING_RECIPIENT_PHONE", "recipient_phone is required"},
    invalid_recipient_phone:
      {:unprocessable_entity, "INVALID_RECIPIENT_PHONE",
       "recipient_phone must be a valid Kenyan phone"},
    recipient_app_account_required:
      {:unprocessable_entity, "RECIPIENT_APP_ACCOUNT_REQUIRED",
       "recipient_phone must belong to a registered app user"},
    missing_item_description:
      {:unprocessable_entity, "MISSING_ITEM_DESCRIPTION", "item_description is required"},
    missing_item_size: {:unprocessable_entity, "MISSING_ITEM_SIZE", "item_size is required"},
    invalid_item_size:
      {:unprocessable_entity, "INVALID_ITEM_SIZE",
       "item_size must be one of: small, medium, large"},
    missing_payer: {:unprocessable_entity, "MISSING_PAYER", "payer is required"},
    invalid_payer:
      {:unprocessable_entity, "INVALID_PAYER", "payer must be either sender or recipient"},
    missing_payment_timing:
      {:unprocessable_entity, "MISSING_PAYMENT_TIMING", "payment_timing is required"},
    invalid_payment_timing:
      {:unprocessable_entity, "INVALID_PAYMENT_TIMING", "payment_timing must be before or after"},
    invalid_send_payment_config:
      {:unprocessable_entity, "INVALID_SEND_PAYMENT_CONFIG",
       "recipient can only pay after delivery"},
    send_liability_ack_required:
      {:unprocessable_entity, "SEND_LIABILITY_ACK_REQUIRED",
       "liability_acknowledged must be true for warned items"},
    invalid_item_value_kes:
      {:unprocessable_entity, "INVALID_ITEM_VALUE_KES",
       "item_value_kes must be a non-negative decimal"},
    invalid_quote_id:
      {:unprocessable_entity, "INVALID_QUOTE_ID", "quote_id must be a positive integer"},
    ride_quote_required:
      {:unprocessable_entity, "RIDE_QUOTE_REQUIRED", "quote_id is required to book a ride"},
    ride_quote_not_found: {:not_found, "RIDE_QUOTE_NOT_FOUND", "Ride quote was not found"},
    ride_quote_expired: {:unprocessable_entity, "RIDE_QUOTE_EXPIRED", "Ride quote has expired"},
    ride_quote_vehicle_category_mismatch:
      {:unprocessable_entity, "RIDE_QUOTE_VEHICLE_CATEGORY_MISMATCH",
       "Ride quote vehicle category does not match request"},
    account_suspended: {:forbidden, "ACCOUNT_SUSPENDED", "This account is currently suspended"},
    account_banned: {:forbidden, "ACCOUNT_BANNED", "This account has been permanently banned"},
    account_deactivated: {:forbidden, "ACCOUNT_DEACTIVATED", "This account has been deactivated"},
    offer_lock_backend_unavailable:
      {:service_unavailable, "DISPATCH_LOCK_BACKEND_UNAVAILABLE",
       "Ride dispatch is temporarily unavailable. Please retry shortly."}
  }

  def quote(conn, params) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.create_send_quote(rider_user_id, params) do
      {:ok, quote} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{quote: RideSerializer.quote_payload(quote)}})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def request(conn, params) do
    rider_user_id = conn.assigns.current_user.id

    Idempotency.execute(
      conn,
      "send.request",
      params,
      fn ->
        case Rides.request_send_delivery(rider_user_id, params) do
          {:ok, payload} ->
            {:ok, 201,
             %{
               data:
                 payload
                 |> RideSerializer.request_payload()
                 |> Map.put(:delivery, payload.delivery)
             }}

          {:error, reason} ->
            {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  def sender_history(conn, params) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.send_sender_history(rider_user_id, params) do
      {:ok, rides} -> json(conn, %{data: RideSerializer.history_payload(rides)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def courier_history(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.send_courier_history(driver_user_id, params) do
      {:ok, rides} -> json(conn, %{data: RideSerializer.history_payload(rides)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    error_response(conn, :unprocessable_entity, "VALIDATION_ERROR", "Validation failed", %{
      details: details
    })
  end

  defp render_error(conn, {:invalid_coordinates, point_key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COORDINATES",
        "Invalid coordinates for #{point_key}"
      )

  defp render_error(conn, {:invalid_route_point, point_key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_ROUTE_POINT",
        "Invalid route point for #{point_key}"
      )

  defp render_error(conn, {:missing_google_maps_env, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_GOOGLE_MAPS_ENV",
        "Missing required Google Maps environment variable: #{key}"
      )

  defp render_error(conn, {:rider_prepay_required, details}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RIDER_PREPAY_REQUIRED",
        "Rider must request with in-app prepay mode before booking",
        details
      )

  defp render_error(conn, {:google_maps_http_error, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "GOOGLE_MAPS_UPSTREAM_HTTP_ERROR",
        "Google Maps #{operation_label(operation)} failed with HTTP #{upstream_status}",
        %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
      )

  defp render_error(
         conn,
         {:google_maps_invalid_response, operation, upstream_status, upstream_body}
       ),
       do:
         error_response(
           conn,
           :bad_gateway,
           "GOOGLE_MAPS_UPSTREAM_INVALID_RESPONSE",
           "Google Maps #{operation_label(operation)} returned an invalid response",
           %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
         )

  defp render_error(conn, {:google_maps_transport_error, operation, reason}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "GOOGLE_MAPS_UPSTREAM_TRANSPORT_ERROR",
        "Google Maps #{operation_label(operation)} transport error",
        %{operation: operation, reason: reason}
      )

  defp render_error(conn, {:prohibited_item_blocked, details}) do
    error_response(
      conn,
      :unprocessable_entity,
      "SEND_PROHIBITED_ITEM_BLOCKED",
      "Item description matches blocked prohibited content",
      details
    )
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        error_response(conn, status, code, message)

      nil ->
        error_response(
          conn,
          :unprocessable_entity,
          "SEND_ERROR",
          "Unable to process send request"
        )
    end
  end

  defp render_error(conn, _reason),
    do:
      error_response(conn, :unprocessable_entity, "SEND_ERROR", "Unable to process send request")

  defp error_response(conn, status, code, message, details \\ nil) do
    error =
      if is_map(details),
        do: Map.merge(%{code: code, message: message}, details),
        else: %{code: code, message: message}

    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp operation_label(:compute_routes), do: "route computation"
  defp operation_label(_unknown), do: "request"
end
