defmodule LiddrWeb.DriverAvailabilityController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.DriverAvailability

  def online(conn, _params) do
    driver_user_id = conn.assigns.current_user.id

    case DriverAvailability.go_online(driver_user_id) do
      {:ok, driver} ->
        json(conn, %{data: availability_payload(driver)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def offline(conn, _params) do
    driver_user_id = conn.assigns.current_user.id

    case DriverAvailability.go_offline(driver_user_id) do
      {:ok, driver} ->
        json(conn, %{data: availability_payload(driver)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp availability_payload(driver) do
    %{
      user_id: driver.user_id,
      subscription_status: driver.subscription_status,
      account_status: driver.account_status,
      verification_status: driver.verification_status,
      is_available: driver.is_available,
      dispatch_status: driver.dispatch_status,
      current_ride_id: driver.current_ride_id,
      last_online_at: driver.last_online_at,
      last_seen_at: driver.last_seen_at
    }
  end

  defp render_error(conn, :driver_profile_not_found),
    do:
      error_response(
        conn,
        :not_found,
        "DRIVER_PROFILE_NOT_FOUND",
        "Driver profile must be initialized first"
      )

  defp render_error(conn, :driver_account_not_active),
    do:
      error_response(
        conn,
        :forbidden,
        "DRIVER_ACCOUNT_NOT_ACTIVE",
        "Driver account is not active"
      )

  defp render_error(conn, :driver_not_verified),
    do:
      error_response(
        conn,
        :forbidden,
        "DRIVER_NOT_VERIFIED",
        "Driver verification status must be approved"
      )

  defp render_error(conn, :driver_subscription_not_active),
    do:
      error_response(
        conn,
        :forbidden,
        "DRIVER_SUBSCRIPTION_NOT_ACTIVE",
        "Driver subscription must be active before going online"
      )

  defp render_error(conn, :driver_has_active_ride),
    do:
      error_response(
        conn,
        :forbidden,
        "DRIVER_HAS_ACTIVE_RIDE",
        "Driver cannot go online while an active ride is in progress"
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
        "DRIVER_AVAILABILITY_ERROR",
        "Unable to update driver availability"
      )

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
