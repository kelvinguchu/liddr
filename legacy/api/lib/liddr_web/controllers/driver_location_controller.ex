defmodule LiddrWeb.DriverLocationController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Location

  def upsert(conn, params) do
    driver_user_id = conn.assigns.current_user.id

    case Location.upsert_driver_location(driver_user_id, params) do
      {:ok, location} ->
        json(conn, %{data: location_payload(location)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp location_payload(location) do
    %{
      driver_id: location.driver_id,
      lat: location.lat,
      lng: location.lng,
      captured_at: location.captured_at,
      updated_at: location.updated_at
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

  defp render_error(conn, :invalid_driver_location),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "INVALID_DRIVER_LOCATION",
        "Driver location coordinates are invalid"
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

  defp render_error(conn, _reason),
    do:
      error_response(
        conn,
        :unprocessable_entity,
        "DRIVER_LOCATION_ERROR",
        "Unable to update driver location"
      )

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
