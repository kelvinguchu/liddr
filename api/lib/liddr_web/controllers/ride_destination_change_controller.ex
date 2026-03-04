defmodule LiddrWeb.RideDestinationChangeController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides
  alias LiddrWeb.RideSerializer

  @known_errors %{
    ride_not_found: {:not_found, "RIDE_NOT_FOUND", "Ride was not found"},
    ride_not_assigned_to_rider:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_RIDER", "Ride does not belong to this rider"},
    ride_not_assigned_to_driver:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_DRIVER", "Ride is not assigned to this driver"},
    ride_destination_change_not_allowed:
      {:unprocessable_entity, "RIDE_DESTINATION_CHANGE_NOT_ALLOWED",
       "Ride destination can only change while trip is in progress"},
    ride_destination_change_not_allowed_for_shared:
      {:unprocessable_entity, "RIDE_DESTINATION_CHANGE_SHARED_NOT_ALLOWED",
       "Destination changes are not allowed for shared rides"},
    destination_change_limit_reached:
      {:unprocessable_entity, "DESTINATION_CHANGE_LIMIT_REACHED",
       "Ride has reached maximum destination changes"},
    destination_change_already_pending:
      {:conflict, "DESTINATION_CHANGE_ALREADY_PENDING",
       "A destination change request is already pending"},
    destination_change_not_found:
      {:not_found, "DESTINATION_CHANGE_NOT_FOUND", "Destination change request was not found"},
    destination_change_same_as_current:
      {:unprocessable_entity, "DESTINATION_CHANGE_SAME_AS_CURRENT",
       "New destination must differ from current dropoff"},
    invalid_destination_coordinates:
      {:unprocessable_entity, "INVALID_DESTINATION_COORDINATES",
       "new_dropoff_lat/new_dropoff_lng must be valid coordinates"},
    invalid_destination_change_reason:
      {:unprocessable_entity, "INVALID_DESTINATION_CHANGE_REASON",
       "reason_code is required and must be a supported value"},
    vehicle_category_not_found:
      {:unprocessable_entity, "VEHICLE_CATEGORY_NOT_FOUND",
       "Vehicle category is missing or inactive"},
    google_maps_http_error:
      {:bad_gateway, "GOOGLE_MAPS_UPSTREAM_HTTP_ERROR", "Google Maps route computation failed"},
    google_maps_invalid_response:
      {:bad_gateway, "GOOGLE_MAPS_UPSTREAM_INVALID_RESPONSE",
       "Google Maps route response was invalid"},
    google_maps_transport_error:
      {:service_unavailable, "GOOGLE_MAPS_UPSTREAM_TRANSPORT_ERROR",
       "Google Maps transport error"}
  }

  def request(conn, %{"ride_id" => ride_id}) do
    rider_user_id = conn.assigns.current_user.id

    case Rides.request_destination_change(rider_user_id, ride_id, conn.body_params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{data: response_payload(payload)})

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def accept(conn, %{"ride_id" => ride_id, "id" => id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.accept_destination_change(driver_user_id, ride_id, id) do
      {:ok, payload} -> json(conn, %{data: response_payload(payload)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def reject(conn, %{"ride_id" => ride_id, "id" => id}) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.reject_destination_change(driver_user_id, ride_id, id, conn.body_params) do
      {:ok, payload} -> json(conn, %{data: response_payload(payload)})
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp response_payload(payload) do
    %{
      ride: RideSerializer.ride_payload(payload.ride),
      destination_change: RideSerializer.destination_change_payload(payload.destination_change)
    }
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "VALIDATION_ERROR", message: "Validation failed", details: details}})
  end

  defp render_error(conn, {:google_maps_http_error, _operation, status, upstream_body}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        code: "GOOGLE_MAPS_UPSTREAM_HTTP_ERROR",
        message: "Google Maps route computation failed with HTTP #{status}",
        upstream_status: status,
        upstream_body: upstream_body
      }
    })
  end

  defp render_error(conn, {:google_maps_invalid_response, _operation, status, upstream_body}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        code: "GOOGLE_MAPS_UPSTREAM_INVALID_RESPONSE",
        message: "Google Maps route response was invalid",
        upstream_status: status,
        upstream_body: upstream_body
      }
    })
  end

  defp render_error(conn, {:google_maps_transport_error, _operation, reason}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "GOOGLE_MAPS_UPSTREAM_TRANSPORT_ERROR",
        message: "Google Maps transport error",
        reason: reason
      }
    })
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        conn |> put_status(status) |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "RIDE_DESTINATION_CHANGE_ERROR", message: "Unable to process request"}
        })
    end
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{code: "RIDE_DESTINATION_CHANGE_ERROR", message: "Unable to process request"}
    })
  end
end
