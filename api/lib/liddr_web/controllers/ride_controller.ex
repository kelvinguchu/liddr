defmodule LiddrWeb.RideController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides
  alias LiddrWeb.RideSerializer

  @known_errors %{
    rider_not_found: {:unprocessable_entity, "RIDER_NOT_FOUND", "Rider account was not found"},
    user_not_found: {:unauthorized, "USER_NOT_FOUND", "User not found"},
    invalid_vehicle_category_id:
      {:unprocessable_entity, "INVALID_VEHICLE_CATEGORY_ID",
       "vehicle_category_id must be a positive integer"},
    invalid_product_type:
      {:unprocessable_entity, "INVALID_PRODUCT_TYPE", "product_type must be solo or shared"},
    vehicle_category_not_found:
      {:unprocessable_entity, "VEHICLE_CATEGORY_NOT_FOUND",
       "Vehicle category is missing or inactive"},
    invalid_quote_id:
      {:unprocessable_entity, "INVALID_QUOTE_ID", "quote_id must be a positive integer"},
    ride_quote_not_found: {:not_found, "RIDE_QUOTE_NOT_FOUND", "Ride quote was not found"},
    ride_quote_expired: {:unprocessable_entity, "RIDE_QUOTE_EXPIRED", "Ride quote has expired"},
    ride_quote_vehicle_category_mismatch:
      {:unprocessable_entity, "RIDE_QUOTE_VEHICLE_CATEGORY_MISMATCH",
       "Ride quote vehicle category does not match request"},
    ride_offer_not_found: {:not_found, "RIDE_OFFER_NOT_FOUND", "Ride offer was not found"},
    offer_not_for_driver:
      {:forbidden, "OFFER_NOT_FOR_DRIVER", "Ride offer does not belong to this driver"},
    ride_offer_not_open:
      {:unprocessable_entity, "RIDE_OFFER_NOT_OPEN", "Ride offer is no longer open"},
    ride_offer_expired: {:unprocessable_entity, "RIDE_OFFER_EXPIRED", "Ride offer has expired"},
    ride_not_assignable:
      {:conflict, "RIDE_NOT_ASSIGNABLE", "Ride is no longer assignable to a driver"},
    driver_profile_not_found:
      {:unprocessable_entity, "DRIVER_PROFILE_NOT_FOUND",
       "Driver profile must be initialized first"},
    account_suspended: {:forbidden, "ACCOUNT_SUSPENDED", "This account is currently suspended"},
    account_banned: {:forbidden, "ACCOUNT_BANNED", "This account has been permanently banned"},
    account_deactivated: {:forbidden, "ACCOUNT_DEACTIVATED", "This account has been deactivated"},
    driver_account_not_active:
      {:forbidden, "DRIVER_ACCOUNT_NOT_ACTIVE", "Driver account is not active"},
    driver_not_verified:
      {:forbidden, "DRIVER_NOT_VERIFIED", "Driver verification status must be approved"},
    driver_subscription_not_active:
      {:forbidden, "DRIVER_SUBSCRIPTION_NOT_ACTIVE", "Driver subscription must be active"},
    driver_not_available:
      {:forbidden, "DRIVER_NOT_AVAILABLE", "Driver must be online before accepting rides"},
    driver_has_active_ride:
      {:forbidden, "DRIVER_HAS_ACTIVE_RIDE", "Driver already has an active ride"},
    ride_not_found: {:not_found, "RIDE_NOT_FOUND", "Ride was not found"},
    ride_not_accessible:
      {:forbidden, "RIDE_NOT_ACCESSIBLE", "Ride is not accessible for this user"},
    ride_not_assigned_to_driver:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_DRIVER", "Ride is not assigned to this driver"},
    ride_not_completable:
      {:unprocessable_entity, "RIDE_NOT_COMPLETABLE",
       "Ride cannot be completed from current status"},
    ride_not_arrivable:
      {:unprocessable_entity, "RIDE_NOT_ARRIVABLE",
       "Ride cannot move to arrival state from current status"},
    driver_location_not_found:
      {:unprocessable_entity, "DRIVER_LOCATION_NOT_FOUND",
       "Driver must share location before this action"},
    driver_location_stale:
      {:unprocessable_entity, "DRIVER_LOCATION_STALE",
       "Driver location is stale. Refresh location and try again"},
    driver_too_far_from_pickup:
      {:unprocessable_entity, "DRIVER_TOO_FAR_FROM_PICKUP",
       "Driver must be near pickup location before marking arrived"},
    driver_too_far_from_dropoff:
      {:unprocessable_entity, "DRIVER_TOO_FAR_FROM_DROPOFF",
       "Driver must be near dropoff location before completing the ride"},
    ride_not_startable:
      {:unprocessable_entity, "RIDE_NOT_STARTABLE", "Ride cannot be started from current status"},
    ride_not_reassignable:
      {:unprocessable_entity, "RIDE_NOT_REASSIGNABLE",
       "Ride cannot be reassigned from current status"},
    reassign_not_recommended:
      {:unprocessable_entity, "REASSIGN_NOT_RECOMMENDED",
       "Reassignment is not recommended from current pickup-health signals"},
    ride_not_cancellable:
      {:unprocessable_entity, "RIDE_NOT_CANCELLABLE",
       "Ride cannot be cancelled from current status"},
    missing_cancel_reason:
      {:unprocessable_entity, "MISSING_CANCEL_REASON", "Cancellation reason is required"},
    invalid_cancel_reason:
      {:unprocessable_entity, "INVALID_CANCEL_REASON",
       "Cancellation reason is not allowed for this action"},
    driver_cancel_requires_emergency_reason:
      {:unprocessable_entity, "DRIVER_CANCEL_REQUIRES_EMERGENCY_REASON",
       "Driver can only cancel an in-progress ride for emergency or safety reasons"},
    ride_not_assigned_to_rider:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_RIDER", "Ride does not belong to this rider"},
    ride_not_no_show_eligible:
      {:unprocessable_entity, "RIDE_NOT_NO_SHOW_ELIGIBLE",
       "Ride cannot be marked as no-show from current status"},
    ride_no_show_wait_not_elapsed:
      {:unprocessable_entity, "RIDE_NO_SHOW_WAIT_NOT_ELAPSED",
       "Driver must wait the configured no-show window after arrival"},
    invalid_payment_mode:
      {:unprocessable_entity, "INVALID_PAYMENT_MODE", "payment_mode must be a supported value"},
    payment_mode_mismatch_for_policy:
      {:unprocessable_entity, "PAYMENT_MODE_POLICY_MISMATCH",
       "payment_mode does not match the required mode for this ride"},
    invalid_final_fare:
      {:unprocessable_entity, "INVALID_FINAL_FARE",
       "final_fare_kes must be greater than or equal to zero"},
    missing_final_fare:
      {:unprocessable_entity, "MISSING_FINAL_FARE",
       "final_fare_kes is required when no quote fare is available"},
    driver_not_locked_to_ride:
      {:unprocessable_entity, "DRIVER_NOT_LOCKED_TO_RIDE", "Driver is not locked to this ride"}
  }

  def quote(conn, params), do: with_rider(conn, params, &Rides.create_quote/2, 201, :quote)

  def request(conn, params), do: with_rider(conn, params, &Rides.request_ride/2, 201, :request)

  def rider_history(conn, params),
    do: with_rider(conn, params, &Rides.rider_history/2, 200, :history)

  def driver_offers(conn, params),
    do: with_driver(conn, params, &Rides.list_driver_offers/2, 200, :driver_offers)

  def driver_history(conn, params),
    do: with_driver(conn, params, &Rides.driver_history/2, 200, :history)

  def show(conn, %{"ride_id" => ride_id}) do
    user_id = conn.assigns.current_user.id

    case Rides.get_ride_for_user(user_id, ride_id) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def events(conn, %{"ride_id" => ride_id} = params) do
    user_id = conn.assigns.current_user.id

    case Rides.list_events_for_user(user_id, ride_id, params) do
      {:ok, %{ride: ride, events: events, next_since: next_since}} ->
        json(conn, %{
          data:
            Map.merge(
              %{ride: RideSerializer.ride_payload(ride)},
              RideSerializer.events_payload(events, next_since)
            )
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def incidents(conn, %{"ride_id" => ride_id} = params) do
    user_id = conn.assigns.current_user.id

    case Rides.list_incidents_for_user(user_id, ride_id, params) do
      {:ok, %{ride: ride, incidents: incidents, summary: summary, next_since: next_since}} ->
        json(conn, %{
          data: %{
            ride: RideSerializer.ride_payload(ride),
            incidents: Enum.map(incidents, &RideSerializer.event_payload/1),
            summary: summary,
            next_since: next_since
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def accept_offer(conn, %{"offer_id" => offer_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.accept_offer(driver_user_id, offer_id) do
      {:ok, payload} -> json(conn, %{data: RideSerializer.accept_payload(payload)})
      {:error, reason} -> render_error(conn, reason)
    end
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

    case Rides.complete_ride(driver_user_id, ride_id, conn.body_params) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
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

    case Rides.start_ride(driver_user_id, ride_id) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def rider_cancel(conn, %{"ride_id" => ride_id}) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.rider_cancel_ride(rider_user_id, ride_id, conn.body_params) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
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

    case Rides.request_reassign(rider_user_id, ride_id, conn.body_params) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def driver_cancel(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.driver_cancel_ride(driver_user_id, ride_id, conn.body_params) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def rider_no_show(conn, %{"ride_id" => ride_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.mark_rider_no_show(driver_user_id, ride_id, conn.body_params) do
      {:ok, ride} -> json(conn, %{data: %{ride: RideSerializer.ride_payload(ride)}})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp with_rider(conn, params, action, status, payload_type) do
    rider_user_id = conn.assigns.current_user.id
    with_user(conn, rider_user_id, params, action, status, payload_type)
  end

  defp with_driver(conn, params, action, status, payload_type) do
    driver_user_id = conn.assigns.current_user.id
    with_user(conn, driver_user_id, params, action, status, payload_type)
  end

  defp with_user(conn, user_id, params, action, status, payload_type) do
    case action.(user_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(status)
        |> json(%{data: serialize_payload(payload_type, payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp serialize_payload(:quote, quote), do: %{quote: RideSerializer.quote_payload(quote)}
  defp serialize_payload(:request, payload), do: RideSerializer.request_payload(payload)
  defp serialize_payload(:history, rides), do: RideSerializer.history_payload(rides)

  defp serialize_payload(:driver_offers, offers) do
    %{offers: Enum.map(offers, &RideSerializer.driver_offer_payload/1)}
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

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        error_response(conn, status, code, message)

      nil ->
        error_response(
          conn,
          :unprocessable_entity,
          "RIDE_ERROR",
          "Unable to process ride request"
        )
    end
  end

  defp render_error(conn, _reason),
    do:
      error_response(conn, :unprocessable_entity, "RIDE_ERROR", "Unable to process ride request")

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
