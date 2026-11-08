defmodule LiddrWeb.RideControllerErrors do
  alias Ecto.Changeset
  import Plug.Conn, only: [put_status: 2]
  import Phoenix.Controller, only: [json: 2]

  @known_errors %{
    rider_not_found: {:unprocessable_entity, "RIDER_NOT_FOUND", "Rider account was not found"},
    user_not_found: {:unauthorized, "USER_NOT_FOUND", "User not found"},
    invalid_vehicle_category_id:
      {:unprocessable_entity, "INVALID_VEHICLE_CATEGORY_ID",
       "vehicle_category_id must be a positive integer"},
    invalid_product_type:
      {:unprocessable_entity, "INVALID_PRODUCT_TYPE", "product_type must be solo or shared"},
    shared_not_supported_for_category:
      {:unprocessable_entity, "SHARED_NOT_SUPPORTED_FOR_CATEGORY",
       "Shared rides are not available for this vehicle category"},
    women_only_rider_not_eligible:
      {:forbidden, "WOMEN_ONLY_RIDER_NOT_ELIGIBLE",
       "Women Only rides are available only to female riders"},
    vehicle_category_not_found:
      {:unprocessable_entity, "VEHICLE_CATEGORY_NOT_FOUND",
       "Vehicle category is missing or inactive"},
    invalid_quote_id:
      {:unprocessable_entity, "INVALID_QUOTE_ID", "quote_id must be a positive integer"},
    ride_quote_not_found: {:not_found, "RIDE_QUOTE_NOT_FOUND", "Ride quote was not found"},
    ride_quote_expired: {:unprocessable_entity, "RIDE_QUOTE_EXPIRED", "Ride quote has expired"},
    ride_request_rate_limited:
      {:too_many_requests, "RIDE_REQUEST_RATE_LIMITED",
       "Too many ride requests in the current window"},
    ride_action_secondary_rate_limited:
      {:too_many_requests, "RIDE_ACTION_SECURITY_RATE_LIMITED",
       "Request pattern is temporarily restricted for security review"},
    ride_quote_vehicle_category_mismatch:
      {:unprocessable_entity, "RIDE_QUOTE_VEHICLE_CATEGORY_MISMATCH",
       "Ride quote vehicle category does not match request"},
    ride_quote_product_type_mismatch:
      {:unprocessable_entity, "RIDE_QUOTE_PRODUCT_TYPE_MISMATCH",
       "Ride quote product_type does not match request"},
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
    driver_presence_unhealthy:
      {:forbidden, "DRIVER_PRESENCE_UNHEALTHY",
       "Driver location signal is stale. Refresh location before accepting rides"},
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
    send_pickup_proof_required:
      {:unprocessable_entity, "SEND_PICKUP_PROOF_REQUIRED",
       "Pickup proof is required before starting this Send ride"},
    send_dropoff_proof_required:
      {:unprocessable_entity, "SEND_DROPOFF_PROOF_REQUIRED",
       "Dropoff proof is required before completing this Send ride"},
    send_recipient_confirmation_pending:
      {:unprocessable_entity, "SEND_RECIPIENT_CONFIRMATION_PENDING",
       "Wait for recipient confirmation or timeout before completing this Send ride"},
    send_ride_required:
      {:unprocessable_entity, "SEND_RIDE_REQUIRED", "This action is only valid for Send rides"},
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
    rider_cancel_rate_limited:
      {:too_many_requests, "RIDER_CANCEL_RATE_LIMITED",
       "Too many rider cancellation attempts in the current window"},
    driver_cancel_rate_limited:
      {:too_many_requests, "DRIVER_CANCEL_RATE_LIMITED",
       "Too many driver cancellation attempts in the current window"},
    driver_no_show_rate_limited:
      {:too_many_requests, "DRIVER_NO_SHOW_RATE_LIMITED",
       "Too many no-show actions in the current window"},
    ride_no_show_wait_not_elapsed:
      {:unprocessable_entity, "RIDE_NO_SHOW_WAIT_NOT_ELAPSED",
       "Driver must wait the configured no-show window after arrival"},
    invalid_payment_mode:
      {:unprocessable_entity, "INVALID_PAYMENT_MODE", "payment_mode must be a supported value"},
    payment_mode_mismatch_for_policy:
      {:unprocessable_entity, "PAYMENT_MODE_POLICY_MISMATCH",
       "payment_mode does not match the required mode for this ride"},
    ride_quote_required:
      {:unprocessable_entity, "RIDE_QUOTE_REQUIRED", "quote_id is required to book a ride"},
    missing_final_fare:
      {:unprocessable_entity, "MISSING_FINAL_FARE", "This ride has no agreed fare"},
    driver_not_locked_to_ride:
      {:unprocessable_entity, "DRIVER_NOT_LOCKED_TO_RIDE", "Driver is not locked to this ride"},
    offer_lock_backend_unavailable:
      {:service_unavailable, "DISPATCH_LOCK_BACKEND_UNAVAILABLE",
       "Ride dispatch is temporarily unavailable. Please retry shortly."}
  }

  def render(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    error_response(conn, :unprocessable_entity, "VALIDATION_ERROR", "Validation failed", %{
      details: details
    })
  end

  def render(conn, {:invalid_coordinates, point_key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COORDINATES",
        "Invalid coordinates for #{point_key}"
      )

  def render(conn, {:invalid_route_point, point_key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_ROUTE_POINT",
        "Invalid route point for #{point_key}"
      )

  def render(conn, {:missing_google_maps_env, key}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_GOOGLE_MAPS_ENV",
        "Missing required Google Maps environment variable: #{key}"
      )

  def render(conn, {:rider_prepay_required, details}),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RIDER_PREPAY_REQUIRED",
        "Rider must request with in-app prepay mode before booking",
        details
      )

  def render(conn, {:google_maps_http_error, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "GOOGLE_MAPS_UPSTREAM_HTTP_ERROR",
        "Google Maps #{operation_label(operation)} failed with HTTP #{upstream_status}",
        %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
      )

  def render(conn, {:google_maps_invalid_response, operation, upstream_status, upstream_body}),
    do:
      error_response(
        conn,
        :bad_gateway,
        "GOOGLE_MAPS_UPSTREAM_INVALID_RESPONSE",
        "Google Maps #{operation_label(operation)} returned an invalid response",
        %{operation: operation, upstream_status: upstream_status, upstream_body: upstream_body}
      )

  def render(conn, {:google_maps_transport_error, operation, reason}),
    do:
      error_response(
        conn,
        :service_unavailable,
        "GOOGLE_MAPS_UPSTREAM_TRANSPORT_ERROR",
        "Google Maps #{operation_label(operation)} transport error",
        %{operation: operation, reason: reason}
      )

  def render(conn, reason) when is_atom(reason) do
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

  def render(conn, _reason),
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
