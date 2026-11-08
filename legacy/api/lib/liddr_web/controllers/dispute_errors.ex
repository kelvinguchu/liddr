defmodule LiddrWeb.DisputeErrors do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @policy_errors %{
    dispute_ride_not_eligible:
      {:unprocessable_entity, "DISPUTE_RIDE_NOT_ELIGIBLE",
       "This ride cannot be disputed in its current state"},
    dispute_window_closed:
      {:unprocessable_entity, "DISPUTE_WINDOW_CLOSED",
       "Disputes must be submitted within 48 hours of the ride ending"},
    dispute_ride_limit_reached:
      {:too_many_requests, "DISPUTE_RIDE_LIMIT_REACHED",
       "Dispute limit reached for this ride. Please contact support"},
    dispute_weekly_limit_reached:
      {:too_many_requests, "DISPUTE_WEEKLY_LIMIT_REACHED",
       "Weekly dispute limit reached. Please contact support"},
    refund_amount_not_allowed:
      {:unprocessable_entity, "REFUND_AMOUNT_NOT_ALLOWED",
       "Refund cannot exceed the ride fare, and a full refund must equal it"},
    refund_fare_unavailable:
      {:unprocessable_entity, "REFUND_FARE_UNAVAILABLE",
       "This ride has no recorded fare to refund against"}
  }
  @policy_error_reasons Map.keys(@policy_errors)

  def render(conn, :invalid_ride_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RIDE_ID",
        "ride_id must be a positive integer"
      )

  def render(conn, :ride_not_found),
    do: error_response(conn, :not_found, "RIDE_NOT_FOUND", "Ride not found")

  def render(conn, :ride_not_assigned_to_user),
    do: error_response(conn, :forbidden, "RIDE_FORBIDDEN", "You are not part of this ride")

  def render(conn, :ride_not_assigned_to_driver),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "RIDE_NOT_ASSIGNED",
        "Ride has no assigned driver to dispute"
      )

  def render(conn, :invalid_dispute_type),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DISPUTE_TYPE",
        "dispute_type is invalid or unsupported"
      )

  def render(conn, :invalid_dispute_description),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DISPUTE_DESCRIPTION",
        "description is required for dispute submission"
      )

  def render(conn, :dispute_create_rate_limited),
    do:
      error_response(
        conn,
        :too_many_requests,
        "DISPUTE_CREATE_RATE_LIMITED",
        "Too many disputes created in the current window"
      )

  def render(conn, :missing_report_category),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_REPORT_CATEGORY",
        "Mapped dispute category is not configured"
      )

  def render(conn, :inactive_report_category),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INACTIVE_REPORT_CATEGORY",
        "Mapped dispute category is inactive"
      )

  def render(conn, :self_report_not_allowed),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SELF_REPORT_NOT_ALLOWED",
        "You cannot dispute yourself"
      )

  def render(conn, :invalid_dispute_resolution_outcome),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DISPUTE_RESOLUTION_OUTCOME",
        "resolution_outcome is invalid"
      )

  def render(conn, :ops_dispute_resolution_rate_limited),
    do:
      error_response(
        conn,
        :too_many_requests,
        "DISPUTE_RESOLVE_RATE_LIMITED",
        "Too many dispute resolution actions in the current window"
      )

  def render(conn, :invalid_resolution_amount),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_RESOLUTION_AMOUNT",
        "resolution_amount_kes must be a positive number for this resolution outcome"
      )

  def render(conn, reason) when reason in @policy_error_reasons do
    {status, code, message} = Map.fetch!(@policy_errors, reason)
    error_response(conn, status, code, message)
  end

  def render(conn, :invalid_dispute_ride_reference),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DISPUTE_RIDE_REFERENCE",
        "Dispute must reference a valid ride"
      )

  def render(conn, :dispute_compensation_conflict),
    do:
      error_response(
        conn,
        :conflict,
        "DISPUTE_COMPENSATION_CONFLICT",
        "Compensation record conflict detected for this dispute"
      )

  def render(conn, :invalid_compensation_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COMPENSATION_ID",
        "Compensation id must be a positive integer"
      )

  def render(conn, :compensation_not_found),
    do: error_response(conn, :not_found, "COMPENSATION_NOT_FOUND", "Compensation not found")

  def render(conn, :invalid_compensation_transition),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COMPENSATION_TRANSITION",
        "Compensation can only transition from approved to paid/cancelled"
      )

  def render(conn, :missing_compensation_processing_reference),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_COMPENSATION_PROCESSING_REFERENCE",
        "processing_reference is required when marking compensation as paid"
      )

  def render(conn, :invalid_compensation_processing_reference),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COMPENSATION_PROCESSING_REFERENCE",
        "processing_reference must be a non-empty string up to 128 characters"
      )

  def render(conn, :invalid_compensation_processing_channel),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_COMPENSATION_PROCESSING_CHANNEL",
        "processing_channel must be one of manual_ops, mpesa_reversal, wallet_credit, bank_transfer"
      )

  def render(conn, :invalid_report_id),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DISPUTE_ID",
        "Dispute id must be a positive integer"
      )

  def render(conn, :dispute_not_found),
    do: error_response(conn, :not_found, "DISPUTE_NOT_FOUND", "Dispute not found")

  def render(conn, :report_not_reviewable),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "DISPUTE_NOT_REVIEWABLE",
        "Dispute cannot be resolved in its current state"
      )

  def render(conn, reason) do
    error_response(
      conn,
      :unprocessable_entity,
      "DISPUTE_REQUEST_INVALID",
      "Unable to process dispute request (#{reason})"
    )
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
