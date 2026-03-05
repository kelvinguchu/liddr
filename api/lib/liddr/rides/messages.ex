defmodule Liddr.Rides.Messages do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.MessageModeration
  alias Liddr.Rides.MessageQuickActions
  alias Liddr.Rides.Realtime
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideMessage
  alias Liddr.Rides.SharedRides.Access
  alias Liddr.Subscriptions.PaymentUtils

  @default_limit 100
  @max_limit 300
  @terminal_statuses ~w(completed cancelled)
  @allowed_message_types ~w(text quick_action)

  def list_for_user(user_id, ride_id, attrs \\ %{}) do
    with {:ok, ride} <- fetch_participant_ride(user_id, ride_id) do
      limit = resolve_limit(attrs)
      since_id = parse_positive_integer(PaymentUtils.get_value(attrs, :since_id))

      query =
        from m in RideMessage,
          where: m.ride_id == ^ride.id,
          order_by: [asc: m.id],
          limit: ^limit

      query = apply_visibility_filter(query, user_id)

      query =
        if is_integer(since_id),
          do: from(m in query, where: m.id > ^since_id),
          else: query

      messages = Repo.all(query)
      next_since_id = messages |> List.last() |> maybe_message_id()

      unread_count =
        Repo.one(
          from m in RideMessage,
            where:
              m.ride_id == ^ride.id and m.recipient_user_id == ^user_id and is_nil(m.read_at) and
                is_nil(m.hidden_for_recipient_at),
            select: count()
        ) || 0

      {:ok,
       %{ride: ride, messages: messages, next_since_id: next_since_id, unread_count: unread_count}}
    end
  end

  def send_for_user(user_id, ride_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- fetch_participant_ride(user_id, ride_id),
         :ok <- ensure_send_allowed!(ride),
         :ok <- MessageModeration.ensure_can_send(user_id),
         {:ok, payload} <- build_message_payload(user_id, ride, attrs),
         {:ok, message} <- create_message(payload),
         {:ok, _event} <- record_message_sent_event(ride.id, user_id, message, now) do
      Realtime.broadcast_ride_message_sent(ride, message, now)
      {:ok, %{ride: ride, message: message}}
    end
  end

  def mark_read_for_user(user_id, ride_id, message_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- fetch_participant_ride(user_id, ride_id),
         {:ok, message} <- fetch_message_for_update(ride.id, message_id),
         :ok <- ensure_recipient!(message, user_id),
         {:ok, updated_message} <- mark_message_read(message, now),
         {:ok, _event} <- record_message_read_event(ride.id, user_id, updated_message, now) do
      Realtime.broadcast_ride_message_read(ride, updated_message, user_id, now)
      {:ok, %{ride: ride, message: updated_message}}
    end
  end

  def hide_for_user(user_id, ride_id, message_id),
    do: MessageModeration.hide_for_user(user_id, ride_id, message_id)

  def report_for_user(user_id, ride_id, message_id, attrs \\ %{}) do
    MessageModeration.report_for_user(user_id, ride_id, message_id, attrs)
  end

  def quick_action_codes, do: MessageQuickActions.codes()

  def fetch_participant_ride(user_id, ride_id) do
    parsed_ride_id = parse_positive_integer(ride_id)

    with true <- is_integer(parsed_ride_id),
         %Ride{} = ride <- fetch_accessible_ride(user_id, parsed_ride_id),
         :ok <- ensure_primary_participant(ride, user_id) do
      {:ok, ride}
    else
      _ -> {:error, :ride_message_forbidden}
    end
  end

  defp fetch_accessible_ride(user_id, ride_id) do
    Ride
    |> Access.scope_for_user(user_id)
    |> where([r], r.id == ^ride_id)
    |> limit(1)
    |> Repo.one()
  end

  defp ensure_primary_participant(%Ride{rider_id: user_id}, user_id), do: :ok
  defp ensure_primary_participant(%Ride{driver_id: user_id}, user_id), do: :ok
  defp ensure_primary_participant(_ride, _user_id), do: {:error, :ride_message_forbidden}

  defp ensure_send_allowed!(%Ride{driver_id: nil}),
    do: {:error, :ride_message_driver_not_assigned}

  defp ensure_send_allowed!(%Ride{status: status}) when status in @terminal_statuses,
    do: {:error, :ride_message_closed}

  defp ensure_send_allowed!(_ride), do: :ok

  defp build_message_payload(user_id, ride, attrs) do
    message_type =
      attrs
      |> PaymentUtils.get_value(:message_type)
      |> normalize_text()
      |> case do
        nil -> "text"
        value -> value
      end

    cond do
      message_type not in @allowed_message_types ->
        {:error, :invalid_ride_message_type}

      message_type == "quick_action" ->
        build_quick_action_payload(user_id, ride, attrs)

      true ->
        build_text_payload(user_id, ride, attrs)
    end
  end

  defp build_text_payload(user_id, ride, attrs) do
    with body when is_binary(body) <- normalize_text(PaymentUtils.get_value(attrs, :body)),
         true <- body != "" do
      {:ok,
       %{
         ride_id: ride.id,
         sender_user_id: user_id,
         recipient_user_id: counterpart_user_id(ride, user_id),
         sender_role: sender_role(ride, user_id),
         message_type: "text",
         body: body,
         metadata: %{}
       }}
    else
      _ -> {:error, :invalid_ride_message_body}
    end
  end

  defp build_quick_action_payload(user_id, ride, attrs) do
    quick_action_code =
      PaymentUtils.get_value(attrs, :quick_action_code) ||
        PaymentUtils.get_value(attrs, :quick_action)

    code = normalize_text(quick_action_code)

    case MessageQuickActions.body_for_code(code || "") do
      nil ->
        {:error, :invalid_ride_message_quick_action}

      body ->
        {:ok,
         %{
           ride_id: ride.id,
           sender_user_id: user_id,
           recipient_user_id: counterpart_user_id(ride, user_id),
           sender_role: sender_role(ride, user_id),
           message_type: "quick_action",
           body: body,
           metadata: %{"quick_action_code" => code}
         }}
    end
  end

  defp create_message(attrs) do
    %RideMessage{}
    |> RideMessage.create_changeset(attrs)
    |> Repo.insert()
  end

  def fetch_message_for_update(ride_id, message_id) do
    parsed_message_id = parse_positive_integer(message_id)

    if is_integer(parsed_message_id) do
      case Repo.one(
             from m in RideMessage,
               where: m.id == ^parsed_message_id and m.ride_id == ^ride_id,
               lock: "FOR UPDATE"
           ) do
        %RideMessage{} = message -> {:ok, message}
        _ -> {:error, :ride_message_not_found}
      end
    else
      {:error, :ride_message_not_found}
    end
  end

  defp ensure_recipient!(%RideMessage{recipient_user_id: user_id}, user_id), do: :ok
  defp ensure_recipient!(_message, _user_id), do: {:error, :ride_message_not_for_user}

  defp mark_message_read(%RideMessage{read_at: %DateTime{}} = message, _now), do: {:ok, message}

  defp mark_message_read(message, now) do
    message
    |> RideMessage.mark_read_changeset(%{"read_at" => now, "acked_at" => now})
    |> Repo.update()
  end

  defp sender_role(%Ride{rider_id: user_id}, user_id), do: "rider"
  defp sender_role(%Ride{driver_id: user_id}, user_id), do: "driver"
  defp sender_role(_ride, _user_id), do: "system"

  defp counterpart_user_id(%Ride{rider_id: user_id, driver_id: driver_id}, user_id), do: driver_id
  defp counterpart_user_id(%Ride{rider_id: rider_id}, _user_id), do: rider_id

  defp apply_visibility_filter(query, user_id) do
    from m in query,
      where:
        (m.sender_user_id != ^user_id or is_nil(m.hidden_for_sender_at)) and
          (m.recipient_user_id != ^user_id or is_nil(m.hidden_for_recipient_at))
  end

  defp resolve_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
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

  defp normalize_text(nil), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp maybe_message_id(%RideMessage{id: id}), do: id
  defp maybe_message_id(_message), do: nil

  defp record_message_sent_event(ride_id, actor_user_id, message, occurred_at) do
    Events.record_event(ride_id, "ride_message_sent", occurred_at,
      actor_user_id: actor_user_id,
      payload: %{
        "message_id" => message.id,
        "message_type" => message.message_type,
        "recipient_user_id" => message.recipient_user_id
      }
    )
  end

  defp record_message_read_event(ride_id, actor_user_id, message, occurred_at) do
    Events.record_event(ride_id, "ride_message_read", occurred_at,
      actor_user_id: actor_user_id,
      payload: %{
        "message_id" => message.id,
        "sender_user_id" => message.sender_user_id,
        "read_at" => message.read_at,
        "acked_at" => message.acked_at
      }
    )
  end
end
