defmodule LiddrWeb.DisputeErrors do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

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

  def render(conn, :missing_resolution_amount),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_RESOLUTION_AMOUNT",
        "resolution_amount_kes is required when the ride has no final fare to infer refund amount"
      )

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
