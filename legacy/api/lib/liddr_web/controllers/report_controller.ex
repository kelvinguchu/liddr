defmodule LiddrWeb.ReportController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Moderation
  alias LiddrWeb.Idempotency

  def categories(conn, params) do
    categories =
      Moderation.list_report_categories(%{
        applies_to: Map.get(params, "applies_to")
      })
      |> Enum.map(&category_payload/1)

    json(conn, %{data: %{categories: categories}})
  end

  def create(conn, params) do
    reporter_id = conn.assigns.current_user.id
    report_params = Map.put(params, "reporter_user_id", reporter_id)

    Idempotency.execute(
      conn,
      "report.create",
      report_params,
      fn ->
        with :ok <- Moderation.enforce_report_create_rate_limit(reporter_id),
             {:ok, report} <- Moderation.submit_report(report_params) do
          {:ok, 201, %{data: report_payload(report)}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &render_error/2
    )
  end

  defp render_error(conn, :missing_report_category),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "MISSING_REPORT_CATEGORY",
        "A valid report category is required"
      )

  defp render_error(conn, :inactive_report_category),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INACTIVE_REPORT_CATEGORY",
        "Selected report category is inactive"
      )

  defp render_error(conn, :reported_driver_required),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORTED_DRIVER_REQUIRED",
        "reported_driver_id is required for driver-specific categories"
      )

  defp render_error(conn, :self_report_not_allowed),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "SELF_REPORT_NOT_ALLOWED",
        "You cannot report yourself"
      )

  defp render_error(conn, :report_create_rate_limited),
    do:
      error_response(
        conn,
        :too_many_requests,
        "REPORT_CREATE_RATE_LIMITED",
        "Too many reports created in the current window"
      )

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "VALIDATION_ERROR",
        message: "Validation failed",
        details: details
      }
    })
  end

  defp render_error(conn, _unknown),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "REPORT_ERROR",
        "Unable to submit report"
      )

  defp category_payload(category) do
    %{
      id: category.id,
      slug: category.slug,
      label: category.label,
      description: category.description,
      applies_to: category.applies_to,
      severity_level_default: category.severity_level_default,
      recommended_action: category.recommended_action,
      requires_immediate_attention: category.requires_immediate_attention
    }
  end

  defp report_payload(report) do
    %{
      id: report.id,
      reporter_user_id: report.reporter_user_id,
      reported_user_id: report.reported_user_id,
      reported_driver_id: report.reported_driver_id,
      category_id: report.category_id,
      status: report.status,
      severity_level: report.severity_level,
      source: report.source,
      incident_type: report.incident_type,
      context_type: report.context_type,
      context_reference: report.context_reference,
      incident_at: report.incident_at,
      description: report.description,
      reporter_contact_opt_in: report.reporter_contact_opt_in,
      is_anonymous_to_reported: report.is_anonymous_to_reported,
      inserted_at: report.inserted_at
    }
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
