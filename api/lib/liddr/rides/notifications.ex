defmodule Liddr.Rides.Notifications do
  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideNotification

  @default_limit 30
  @max_limit 100
  @ride_cancelled_event_type "ride_cancelled"
  @sticky_event_types ~w(
    ride_assigned
    driver_arriving
    driver_arrived
    trip_started
    trip_cancelled
    ride_completed
    ride_reassigned
    destination_change_requested
    destination_change_accepted
    destination_change_rejected
    send_pickup_proof_captured
    send_dropoff_proof_captured
    send_recipient_confirmed
    shared_eta_updated
    rating_pending
    rating_submitted
    rating_skipped
    ride_cancelled
  )

  def queue_ride_cancelled!(%Ride{} = ride, actor_user_id, reason_code, occurred_at) do
    queue_event!(
      ride,
      @ride_cancelled_event_type,
      %{
        "reason_code" => to_string(reason_code),
        "actor_user_id" => actor_user_id,
        "ride_status" => ride.status
      },
      occurred_at
    )
  end

  def mark_socket_sent(ride_id, event_type, recipient_user_ids, occurred_at) do
    recipient_user_ids = normalize_recipient_ids(recipient_user_ids)

    if recipient_user_ids == [] do
      {0, nil}
    else
      Repo.update_all(
        from(n in RideNotification,
          where:
            n.ride_id == ^ride_id and n.event_type == ^to_string(event_type) and
              n.recipient_user_id in ^recipient_user_ids
        ),
        set: [socket_status: "sent", last_attempt_at: occurred_at, updated_at: occurred_at],
        inc: [attempt_count: 1]
      )
    end
  end

  def queue_realtime_event!(%Ride{} = ride, event_type, payload, occurred_at) do
    event_type = to_string(event_type)

    if event_type in @sticky_event_types do
      queue_event!(ride, event_type, payload, occurred_at)
    else
      []
    end
  end

  def queue_event_for_user!(ride_id, recipient_user_id, event_type, payload, occurred_at) do
    row = %{
      ride_id: ride_id,
      recipient_user_id: recipient_user_id,
      event_type: to_string(event_type),
      socket_status: "pending",
      push_status: "pending",
      poll_status: "pending",
      payload: normalize_payload(payload),
      inserted_at: occurred_at,
      updated_at: occurred_at
    }

    {_, inserted} = Repo.insert_all(RideNotification, [row], returning: [:recipient_user_id])
    Enum.map(inserted, &Map.get(&1, :recipient_user_id))
  end

  def list_for_user(user_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)
    include_acked = parse_bool(get_value(attrs, :include_acked), false)

    query =
      from n in RideNotification,
        where: n.recipient_user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit

    query =
      if include_acked do
        query
      else
        from n in query, where: n.socket_status != "acked"
      end

    {:ok, Repo.all(query)}
  end

  def list_for_ride(ride_id, attrs \\ %{})

  def list_for_ride(ride_id, attrs) when is_integer(ride_id) and ride_id > 0 do
    limit = resolve_limit(attrs)
    include_acked = parse_bool(get_value(attrs, :include_acked), true)

    query =
      from n in RideNotification,
        where: n.ride_id == ^ride_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit

    query =
      if include_acked do
        query
      else
        from n in query, where: n.socket_status != "acked"
      end

    {:ok, Repo.all(query)}
  end

  def list_for_ride(_ride_id, _attrs), do: {:error, :invalid_ride_id}

  def ack_for_user(
        user_id,
        notification_id,
        acked_at \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ) do
    with parsed_id when is_integer(parsed_id) <- parse_positive_integer(notification_id),
         %RideNotification{} = notification <-
           Repo.get_by(RideNotification, id: parsed_id, recipient_user_id: user_id) do
      case notification
           |> RideNotification.create_changeset(%{
             "socket_status" => "acked",
             "poll_status" => "acked",
             "acked_at" => acked_at,
             "last_attempt_at" => acked_at
           })
           |> Repo.update() do
        {:ok, updated} ->
          _ =
            Events.record_event(updated.ride_id, "ride_notification_acked", acked_at,
              actor_user_id: user_id,
              payload: %{
                "notification_id" => updated.id,
                "event_type" => updated.event_type
              }
            )

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      _ -> {:error, :notification_not_found}
    end
  end

  defp recipient_user_ids(%Ride{} = ride) do
    [ride.rider_id, ride.driver_id]
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp normalize_recipient_ids(recipient_user_ids) do
    recipient_user_ids
    |> List.wrap()
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp queue_event!(%Ride{} = ride, event_type, payload, occurred_at) do
    recipient_user_ids = recipient_user_ids(ride)

    rows =
      Enum.map(recipient_user_ids, fn recipient_user_id ->
        %{
          ride_id: ride.id,
          recipient_user_id: recipient_user_id,
          event_type: to_string(event_type),
          socket_status: "pending",
          push_status: "pending",
          poll_status: "pending",
          payload: normalize_payload(payload),
          inserted_at: occurred_at,
          updated_at: occurred_at
        }
      end)

    if rows == [] do
      []
    else
      {_, inserted} =
        Repo.insert_all(RideNotification, rows, returning: [:recipient_user_id])

      Enum.map(inserted, &Map.get(&1, :recipient_user_id))
    end
  end

  defp normalize_payload(%{} = payload), do: payload
  defp normalize_payload(_payload), do: %{}

  defp resolve_limit(attrs) do
    attrs
    |> get_value(:limit)
    |> parse_positive_integer()
    |> case do
      nil -> @default_limit
      value when value > @max_limit -> @max_limit
      value -> value
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp parse_bool(value, default) do
    case value do
      value when value in [true, "true", "1", "yes", "on"] -> true
      value when value in [false, "false", "0", "no", "off"] -> false
      _ -> default
    end
  end

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil
end
