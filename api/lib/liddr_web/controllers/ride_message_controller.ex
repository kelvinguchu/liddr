defmodule LiddrWeb.RideMessageController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides
  alias Liddr.Rides.MessageQuickActions
  alias LiddrWeb.RequestMeta
  alias LiddrWeb.RideSerializer

  @error_mappings %{
    ride_message_forbidden:
      {:forbidden, "RIDE_MESSAGE_FORBIDDEN",
       "Only the rider and currently assigned driver can access ride messages"},
    ride_message_driver_not_assigned:
      {:unprocessable_entity, "RIDE_MESSAGE_DRIVER_NOT_ASSIGNED",
       "Ride messages require an assigned driver"},
    ride_message_closed:
      {:unprocessable_entity, "RIDE_MESSAGE_CLOSED", "Ride messages are closed for this ride"},
    invalid_ride_message_type:
      {:unprocessable_entity, "INVALID_RIDE_MESSAGE_TYPE",
       "message_type must be text or quick_action"},
    invalid_ride_message_quick_action:
      {:unprocessable_entity, "INVALID_RIDE_MESSAGE_QUICK_ACTION", "quick_action_code is invalid"},
    invalid_ride_message_body:
      {:unprocessable_entity, "INVALID_RIDE_MESSAGE_BODY", "body must be a non-empty string"},
    ride_message_not_found: {:not_found, "RIDE_MESSAGE_NOT_FOUND", "Ride message was not found"},
    ride_message_not_for_user:
      {:forbidden, "RIDE_MESSAGE_NOT_FOR_USER", "Ride message is not addressed to this user"},
    ride_message_communication_restricted:
      {:forbidden, "RIDE_MESSAGE_COMMUNICATION_RESTRICTED",
       "Messaging is temporarily restricted for this account"},
    ride_message_rate_limited:
      {:too_many_requests, "RIDE_MESSAGE_RATE_LIMITED",
       "Too many ride messages sent in the current window"},
    ride_message_report_rate_limited:
      {:too_many_requests, "RIDE_MESSAGE_REPORT_RATE_LIMITED",
       "Too many ride message reports submitted in the current window"},
    ride_action_secondary_rate_limited:
      {:too_many_requests, "RIDE_ACTION_SECURITY_RATE_LIMITED",
       "Request pattern is temporarily restricted for security review"},
    ride_message_self_report_not_allowed:
      {:unprocessable_entity, "RIDE_MESSAGE_SELF_REPORT_NOT_ALLOWED",
       "You cannot report your own message"},
    invalid_ride_message_report_description:
      {:unprocessable_entity, "INVALID_RIDE_MESSAGE_REPORT_DESCRIPTION",
       "description must be a non-empty string"},
    missing_report_category:
      {:unprocessable_entity, "MISSING_REPORT_CATEGORY", "A valid report category is required"},
    inactive_report_category:
      {:unprocessable_entity, "INACTIVE_REPORT_CATEGORY", "Selected report category is inactive"},
    reported_driver_required:
      {:unprocessable_entity, "REPORTED_DRIVER_REQUIRED",
       "reported_driver_id is required for driver-specific categories"}
  }

  def quick_actions(conn, params) do
    locale = request_locale(conn, params)

    actions =
      Rides.quick_action_codes()
      |> Enum.map(&MessageQuickActions.payload(&1, locale))
      |> Enum.reject(&is_nil/1)

    json(conn, %{data: %{quick_actions: actions}})
  end

  def index(conn, %{"ride_id" => ride_id} = params) do
    user_id = conn.assigns.current_user.id
    locale = request_locale(conn, params)

    case Rides.list_ride_messages(user_id, ride_id, params) do
      {:ok, payload} ->
        json(conn, %{data: list_payload(payload, locale)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def create(conn, %{"ride_id" => ride_id} = params) do
    user_id = conn.assigns.current_user.id
    locale = request_locale(conn, params)

    with :ok <-
           Rides.enforce_action_security_signals(
             :ride_message_send,
             user_id,
             RequestMeta.security(conn)
           ),
         :ok <- Rides.enforce_message_send_rate_limit(user_id),
         {:ok, payload} <- Rides.send_ride_message(user_id, ride_id, params) do
      conn
      |> put_status(:created)
      |> json(%{data: message_payload(payload, locale)})
    else
      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def mark_read(conn, %{"ride_id" => ride_id, "id" => message_id}) do
    user_id = conn.assigns.current_user.id
    locale = request_locale(conn, %{})

    case Rides.mark_ride_message_read(user_id, ride_id, message_id) do
      {:ok, payload} ->
        json(conn, %{data: message_payload(payload, locale)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def hide(conn, %{"ride_id" => ride_id, "id" => message_id}) do
    user_id = conn.assigns.current_user.id
    locale = request_locale(conn, %{})

    case Rides.hide_ride_message(user_id, ride_id, message_id) do
      {:ok, payload} ->
        json(conn, %{data: message_payload(payload, locale)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def report(conn, %{"ride_id" => ride_id, "id" => message_id} = params) do
    user_id = conn.assigns.current_user.id
    locale = request_locale(conn, params)

    with :ok <- Rides.enforce_message_report_rate_limit(user_id),
         {:ok, payload} <- Rides.report_ride_message(user_id, ride_id, message_id, params) do
      conn
      |> put_status(:created)
      |> json(%{data: report_payload(payload, locale)})
    else
      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp list_payload(payload, locale) do
    %{
      ride: RideSerializer.ride_payload(payload.ride),
      messages: Enum.map(payload.messages, &RideSerializer.message_payload(&1, locale: locale)),
      next_since_id: payload.next_since_id,
      unread_count: payload.unread_count
    }
  end

  defp message_payload(payload, locale) do
    %{
      ride: RideSerializer.ride_payload(payload.ride),
      message: RideSerializer.message_payload(payload.message, locale: locale)
    }
  end

  defp report_payload(payload, locale) do
    %{
      ride: RideSerializer.ride_payload(payload.ride),
      message: RideSerializer.message_payload(payload.message, locale: locale),
      report: %{
        id: payload.report.id,
        category_id: payload.report.category_id,
        status: payload.report.status,
        severity_level: payload.report.severity_level,
        context_type: payload.report.context_type,
        context_reference: payload.report.context_reference,
        inserted_at: payload.report.inserted_at
      }
    }
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "VALIDATION_ERROR", message: "Validation failed", details: details}})
  end

  defp render_error(conn, reason) do
    case Map.get(@error_mappings, reason) do
      {status, code, message} ->
        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "RIDE_MESSAGE_ERROR", message: "Unable to process ride message request"}
        })
    end
  end

  defp request_locale(conn, params) do
    explicit = Map.get(params, "locale")
    header = conn |> get_req_header("accept-language") |> List.first()
    MessageQuickActions.resolve_locale(explicit || header)
  end
end
