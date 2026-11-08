defmodule LiddrWeb.SendDeliveryController do
  use LiddrWeb, :controller

  alias Ecto.Changeset
  alias Liddr.Rides
  alias LiddrWeb.RideSerializer
  alias LiddrWeb.SendDeliverySerializer

  @known_errors %{
    ride_not_found: {:not_found, "RIDE_NOT_FOUND", "Ride was not found"},
    ride_not_assigned_to_driver:
      {:forbidden, "RIDE_NOT_ASSIGNED_TO_DRIVER", "Ride is not assigned to this driver"},
    driver_profile_not_found:
      {:unprocessable_entity, "DRIVER_PROFILE_NOT_FOUND",
       "Driver profile must be initialized first"},
    driver_not_locked_to_ride:
      {:unprocessable_entity, "DRIVER_NOT_LOCKED_TO_RIDE", "Driver is not locked to this ride"},
    send_ride_required:
      {:unprocessable_entity, "SEND_RIDE_REQUIRED", "This endpoint is only valid for Send rides"},
    send_delivery_details_missing:
      {:unprocessable_entity, "SEND_DELIVERY_DETAILS_MISSING",
       "Ride is missing required delivery details"},
    send_pickup_proof_not_allowed:
      {:unprocessable_entity, "SEND_PICKUP_PROOF_NOT_ALLOWED",
       "Pickup proof can only be captured after arriving at pickup"},
    send_dropoff_proof_not_allowed:
      {:unprocessable_entity, "SEND_DROPOFF_PROOF_NOT_ALLOWED",
       "Dropoff proof can only be captured while ride is in progress"},
    send_pickup_proof_required:
      {:unprocessable_entity, "SEND_PICKUP_PROOF_REQUIRED",
       "Pickup proof is required before this action"},
    send_dropoff_proof_required:
      {:unprocessable_entity, "SEND_DROPOFF_PROOF_REQUIRED",
       "Dropoff proof is required before completing this Send ride"},
    send_recipient_confirmation_pending:
      {:unprocessable_entity, "SEND_RECIPIENT_CONFIRMATION_PENDING",
       "Wait for recipient confirmation or configured timeout before completion"},
    missing_pickup_proof_key:
      {:unprocessable_entity, "MISSING_PICKUP_PROOF_KEY", "pickup_proof_key is required"},
    missing_dropoff_proof_key:
      {:unprocessable_entity, "MISSING_DROPOFF_PROOF_KEY", "dropoff_proof_key is required"},
    send_recipient_in_app_only:
      {:unprocessable_entity, "SEND_RECIPIENT_IN_APP_ONLY",
       "Recipient confirmation is only available in-app"},
    recipient_not_authorized_for_delivery:
      {:forbidden, "RECIPIENT_NOT_AUTHORIZED_FOR_DELIVERY",
       "Current user is not authorized to confirm this delivery"}
  }

  def pickup_proof(conn, %{"ride_id" => ride_id} = params) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.capture_send_pickup_proof(driver_user_id, ride_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            ride: RideSerializer.ride_payload(payload.ride),
            delivery: SendDeliverySerializer.delivery_payload(payload.delivery)
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def dropoff_proof(conn, %{"ride_id" => ride_id} = params) do
    driver_user_id = conn.assigns.current_user.id

    case Rides.capture_send_dropoff_proof(driver_user_id, ride_id, params) do
      {:ok, payload} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            ride: RideSerializer.ride_payload(payload.ride),
            delivery: SendDeliverySerializer.delivery_payload(payload.delivery),
            recipient_confirmation_channel: payload.recipient_confirmation_channel
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  def confirm_recipient_in_app(conn, %{"ride_id" => ride_id} = params) do
    recipient_user_id = conn.assigns.current_user.id

    case Rides.confirm_send_recipient_in_app(recipient_user_id, ride_id, params) do
      {:ok, payload} ->
        json(conn, %{
          data: %{
            ride_id: payload.ride.id,
            delivery: SendDeliverySerializer.delivery_payload(payload.delivery)
          }
        })

      {:error, reason} ->
        render_error(conn, reason)
    end
  end

  defp render_error(conn, %Changeset{} = changeset) do
    details = Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "VALIDATION_ERROR", message: "Validation failed", details: details}})
  end

  defp render_error(conn, reason) when is_atom(reason) do
    case Map.get(@known_errors, reason) do
      {status, code, message} ->
        conn
        |> put_status(status)
        |> json(%{error: %{code: code, message: message}})

      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "SEND_DELIVERY_ERROR", message: "Unable to process send delivery action"}
        })
    end
  end

  defp render_error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{code: "SEND_DELIVERY_ERROR", message: "Unable to process send delivery action"}
    })
  end
end
