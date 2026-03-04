defmodule Liddr.Rides.SendDeliveries do
  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.SendDelivery
  alias Liddr.Rides.SendDeliverySupport
  alias Liddr.Rides.Ride

  def capture_pickup_proof(driver_user_id, ride_id, attrs \\ %{}) do
    with {:ok, pickup_proof_key} <-
           SendDeliverySupport.required_text(attrs, :pickup_proof_key, :missing_pickup_proof_key) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_driver_owns_ride!(ride, driver_user_id)
        driver = Shared.fetch_driver_for_update!(driver_user_id)
        Shared.ensure_driver_locked_to_ride!(driver, ride.id)
        SendDeliverySupport.ensure_send_ride!(ride)

        if ride.status not in ["arrived", "in_progress"] do
          Repo.rollback(:send_pickup_proof_not_allowed)
        end

        delivery = SendDeliverySupport.ensure_delivery_for_ride!(ride, now)
        transition? = is_nil(delivery.pickup_proof_captured_at)

        delivery =
          SendDeliverySupport.update_delivery!(
            delivery,
            %{
              "pickup_proof_key" => pickup_proof_key,
              "pickup_proof_captured_at" => delivery.pickup_proof_captured_at || now
            }
          )

        if transition? do
          _ =
            Events.record_event(ride.id, "send_pickup_proof_captured", now,
              actor_user_id: driver_user_id,
              payload: %{"pickup_proof_key" => pickup_proof_key}
            )
            |> Shared.unwrap_or_rollback()
        end

        %{ride: ride, delivery: delivery, transition?: transition?}
      end)
      |> Shared.unwrap_transaction_result()
      |> case do
        {:ok, %{ride: ride, delivery: delivery, transition?: true} = payload} ->
          Realtime.broadcast_send_pickup_proof_captured(ride, delivery)
          {:ok, payload}

        other ->
          other
      end
    end
  end

  def capture_dropoff_proof(driver_user_id, ride_id, attrs \\ %{}) do
    with {:ok, dropoff_proof_key} <-
           SendDeliverySupport.required_text(
             attrs,
             :dropoff_proof_key,
             :missing_dropoff_proof_key
           ) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.transaction(fn ->
        ride = Shared.fetch_ride_for_update!(ride_id)
        Shared.ensure_driver_owns_ride!(ride, driver_user_id)
        driver = Shared.fetch_driver_for_update!(driver_user_id)
        Shared.ensure_driver_locked_to_ride!(driver, ride.id)
        SendDeliverySupport.ensure_send_ride!(ride)

        if ride.status != "in_progress" do
          Repo.rollback(:send_dropoff_proof_not_allowed)
        end

        delivery = SendDeliverySupport.ensure_delivery_for_ride!(ride, now)

        if is_nil(delivery.pickup_proof_captured_at) do
          Repo.rollback(:send_pickup_proof_required)
        end

        delivery =
          SendDeliverySupport.update_delivery!(
            delivery,
            %{
              "dropoff_proof_key" => dropoff_proof_key,
              "dropoff_proof_captured_at" => now,
              "recipient_confirmation_token_hash" => nil,
              "recipient_confirmation_expires_at" => nil,
              "recipient_confirmation_status" => "pending",
              "delivery_status" => "delivered_pending_confirmation"
            }
          )

        _ =
          Events.record_event(ride.id, "send_dropoff_proof_captured", now,
            actor_user_id: driver_user_id,
            payload: %{
              "dropoff_proof_key" => dropoff_proof_key,
              "recipient_confirmation_expires_at" => nil,
              "completion_wait_seconds" => SendDeliverySupport.confirmation_wait_seconds()
            }
          )
          |> Shared.unwrap_or_rollback()

        recipient_user_id = recipient_user_id(delivery.recipient_phone)

        %{
          ride: ride,
          delivery: delivery,
          recipient_user_id: recipient_user_id,
          recipient_confirmation_channel: "in_app"
        }
      end)
      |> Shared.unwrap_transaction_result()
      |> case do
        {:ok, %{ride: ride, delivery: delivery, recipient_user_id: recipient_user_id} = payload} ->
          maybe_queue_in_app_confirmation_notification(ride.id, recipient_user_id)

          Realtime.broadcast_send_dropoff_proof_captured(ride, delivery)
          {:ok, payload}

        other ->
          other
      end
    end
  end

  def confirm_recipient(_token, _attrs \\ %{}), do: {:error, :send_recipient_in_app_only}

  def confirm_recipient_in_app(recipient_user_id, ride_id, _attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.transaction(fn ->
      ride = Shared.fetch_ride_for_update!(ride_id)
      SendDeliverySupport.ensure_send_ride!(ride)

      delivery =
        Repo.get_by(SendDelivery, ride_id: ride.id) || Repo.rollback(:send_dropoff_proof_required)

      recipient =
        Repo.get(User, recipient_user_id) || Repo.rollback(:recipient_confirmation_not_found)

      if recipient.phone != delivery.recipient_phone do
        Repo.rollback(:recipient_not_authorized_for_delivery)
      end

      cond do
        not is_nil(delivery.recipient_confirmed_at) ->
          %{ride: ride, delivery: delivery, transition?: false}

        true ->
          delivery =
            SendDeliverySupport.update_delivery!(
              delivery,
              %{
                "recipient_confirmed_at" => now,
                "recipient_confirmation_status" => "confirmed",
                "recipient_confirmation_token_hash" => nil,
                "recipient_confirmation_expires_at" => nil,
                "delivery_status" => "delivered_confirmed"
              }
            )

          _ =
            Events.record_event(ride.id, "send_recipient_confirmed", now,
              actor_user_id: recipient_user_id,
              payload: %{"confirmed_at" => now, "channel" => "in_app"}
            )
            |> Shared.unwrap_or_rollback()

          %{ride: ride, delivery: delivery, transition?: true}
      end
    end)
    |> Shared.unwrap_transaction_result()
    |> case do
      {:ok, %{ride: ride, delivery: delivery, transition?: true} = payload} ->
        Realtime.broadcast_send_recipient_confirmed(ride, delivery)
        {:ok, payload}

      other ->
        other
    end
  end

  def ensure_start_allowed!(%Ride{} = ride) do
    if SendDeliverySupport.send_ride?(ride) do
      delivery = Repo.get_by(SendDelivery, ride_id: ride.id)

      if delivery && is_binary(delivery.pickup_proof_key) &&
           not is_nil(delivery.pickup_proof_captured_at) do
        :ok
      else
        Repo.rollback(:send_pickup_proof_required)
      end
    else
      :ok
    end
  end

  def ensure_completion_allowed!(%Ride{} = ride, now) do
    if SendDeliverySupport.send_ride?(ride) do
      delivery =
        Repo.get_by(SendDelivery, ride_id: ride.id) || Repo.rollback(:send_dropoff_proof_required)

      cond do
        is_nil(delivery.dropoff_proof_captured_at) ->
          Repo.rollback(:send_dropoff_proof_required)

        not is_nil(delivery.recipient_confirmed_at) ->
          :ok

        SendDeliverySupport.completion_wait_elapsed?(delivery, now) ->
          :ok

        true ->
          Repo.rollback(:send_recipient_confirmation_pending)
      end
    else
      :ok
    end
  end

  def mark_completed!(%Ride{} = ride) do
    if SendDeliverySupport.send_ride?(ride) do
      delivery =
        Repo.get_by(SendDelivery, ride_id: ride.id) || Repo.rollback(:send_dropoff_proof_required)

      SendDeliverySupport.update_delivery!(delivery, %{"delivery_status" => "completed"})
    else
      :ok
    end
  end

  defp recipient_user_id(phone) when is_binary(phone) do
    Repo.one(from u in User, where: u.phone == ^phone, select: u.id, limit: 1)
  end

  defp recipient_user_id(_phone), do: nil

  defp maybe_queue_in_app_confirmation_notification(_ride_id, recipient_user_id)
       when not is_integer(recipient_user_id),
       do: :ok

  defp maybe_queue_in_app_confirmation_notification(ride_id, recipient_user_id) do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    _ =
      Notifications.queue_event_for_user!(
        ride_id,
        recipient_user_id,
        "send_recipient_confirmation_required",
        %{"ride_id" => ride_id},
        occurred_at
      )

    :ok
  end
end
