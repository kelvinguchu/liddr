defmodule LiddrWeb.SharedRideController do
  use LiddrWeb, :controller

  alias Liddr.Rides
  alias LiddrWeb.SharedRideSerializer

  @known_errors %{
    ride_not_accessible:
      {:forbidden, "RIDE_NOT_ACCESSIBLE", "Ride is not accessible for this user"},
    shared_not_enabled_for_ride:
      {:unprocessable_entity, "SHARED_NOT_ENABLED_FOR_RIDE", "Ride is not a shared ride"},
    shared_member_not_found:
      {:not_found, "SHARED_MEMBER_NOT_FOUND", "Shared ride member was not found"},
    shared_member_forbidden:
      {:forbidden, "SHARED_MEMBER_FORBIDDEN", "Shared ride member does not belong to this rider"},
    shared_member_action_not_supported:
      {:unprocessable_entity, "SHARED_MEMBER_ACTION_NOT_SUPPORTED",
       "Action is not supported for this shared ride member in v1"},
    shared_member_not_pickup_ready:
      {:unprocessable_entity, "SHARED_MEMBER_NOT_PICKUP_READY",
       "Shared member is not ready for pickup action"},
    shared_member_not_dropoff_ready:
      {:unprocessable_entity, "SHARED_MEMBER_NOT_DROPOFF_READY",
       "Shared member is not ready for dropoff action"},
    ride_not_assigned_to_driver:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_DRIVER", "Ride is not assigned to this driver"},
    ride_not_no_show_eligible:
      {:unprocessable_entity, "RIDE_NOT_NO_SHOW_ELIGIBLE",
       "Ride cannot be marked as no-show from current status"},
    ride_no_show_wait_not_elapsed:
      {:unprocessable_entity, "RIDE_NO_SHOW_WAIT_NOT_ELAPSED",
       "Driver must wait the configured no-show window after arrival"},
    missing_cancel_reason:
      {:unprocessable_entity, "MISSING_CANCEL_REASON", "Cancellation reason is required"},
    invalid_cancel_reason:
      {:unprocessable_entity, "INVALID_CANCEL_REASON",
       "Cancellation reason is not allowed for this action"},
    ride_not_cancellable:
      {:unprocessable_entity, "RIDE_NOT_CANCELLABLE",
       "Ride cannot be cancelled from current status"}
  }

  def show(conn, %{"ride_id" => ride_id}) do
    user_id = conn.assigns.current_user.id

    case Rides.shared_context_for_user(user_id, ride_id) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def cancel_member(conn, %{"ride_id" => ride_id, "member_id" => member_id}) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.rider_cancel_shared_member(rider_user_id, ride_id, member_id, conn.body_params) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_member_no_show(conn, %{"ride_id" => ride_id, "member_id" => member_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.driver_mark_shared_member_no_show(
           driver_user_id,
           ride_id,
           member_id,
           conn.body_params
         ) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def arrive_member_pickup(conn, %{"ride_id" => ride_id, "member_id" => member_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.driver_arrive_shared_member_pickup(driver_user_id, ride_id, member_id) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_member_picked_up(conn, %{"ride_id" => ride_id, "member_id" => member_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.driver_mark_shared_member_picked_up(driver_user_id, ride_id, member_id) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def mark_member_dropped_off(conn, %{"ride_id" => ride_id, "member_id" => member_id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.driver_mark_shared_member_dropped_off(driver_user_id, ride_id, member_id) do
      {:ok, context} -> json(conn, %{data: SharedRideSerializer.context_payload(context)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        conn |> put_status(status) |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "SHARED_RIDE_ERROR", message: "Unable to process shared ride"}})
    end
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "SHARED_RIDE_ERROR", message: "Unable to process shared ride"}})
  end
end
