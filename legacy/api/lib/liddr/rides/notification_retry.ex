defmodule Liddr.Rides.NotificationRetry do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.RideNotification

  @default_limit 100
  @max_limit 500
  @default_max_attempts 3
  @default_retry_interval_seconds 30

  def run(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    policy = resolve_policy(attrs)
    cutoff = DateTime.add(now, -policy.retry_interval_seconds, :second)
    exhausted_count = mark_exhausted_pending_as_failed(now, policy.max_attempts)

    candidate_ids = fetch_candidate_ids(cutoff, policy)

    result =
      Enum.reduce(candidate_ids, init_result(exhausted_count), fn notification_id, acc ->
        process_candidate(notification_id, now, cutoff, policy, acc)
      end)

    {:ok, Map.put(result, :processed, length(candidate_ids))}
  end

  defp process_candidate(notification_id, now, cutoff, policy, acc) do
    case reserve_attempt(notification_id, now, cutoff, policy.max_attempts) do
      {:ok, notification} ->
        payload = push_payload(notification)

        case push_client().send_ride_notification(payload) do
          :ok ->
            mark_push_sent(notification_id, now)
            %{acc | sent: acc.sent + 1}

          {:error, reason} ->
            attempt_count = notification.attempt_count

            status =
              mark_retry_or_failure(notification_id, now, attempt_count, policy.max_attempts)

            case status do
              :failed -> %{acc | failed: acc.failed + 1}
              :pending -> %{acc | retry_scheduled: acc.retry_scheduled + 1}
            end
            |> append_error(reason)
        end

      :skip ->
        %{acc | skipped: acc.skipped + 1}
    end
  end

  defp fetch_candidate_ids(cutoff, policy) do
    from(n in RideNotification,
      where:
        n.push_status == "pending" and is_nil(n.acked_at) and
          n.attempt_count < ^policy.max_attempts and
          (is_nil(n.last_attempt_at) or n.last_attempt_at <= ^cutoff),
      order_by: [asc: n.inserted_at, asc: n.id],
      limit: ^policy.limit,
      select: n.id
    )
    |> Repo.all()
  end

  defp reserve_attempt(notification_id, now, cutoff, max_attempts) do
    query =
      from(n in RideNotification,
        where:
          n.id == ^notification_id and n.push_status == "pending" and is_nil(n.acked_at) and
            n.attempt_count < ^max_attempts and
            (is_nil(n.last_attempt_at) or n.last_attempt_at <= ^cutoff)
      )

    case Repo.update_all(query,
           set: [last_attempt_at: now, updated_at: now],
           inc: [attempt_count: 1]
         ) do
      {1, _} -> {:ok, fetch_notification!(notification_id)}
      _ -> :skip
    end
  end

  defp fetch_notification!(notification_id) do
    Repo.one!(
      from(n in RideNotification,
        where: n.id == ^notification_id,
        select: %{
          id: n.id,
          ride_id: n.ride_id,
          recipient_user_id: n.recipient_user_id,
          event_type: n.event_type,
          payload: n.payload,
          attempt_count: n.attempt_count
        }
      )
    )
  end

  defp mark_push_sent(notification_id, now) do
    Repo.update_all(
      from(n in RideNotification, where: n.id == ^notification_id),
      set: [push_status: "sent", updated_at: now]
    )
  end

  defp mark_retry_or_failure(notification_id, now, attempt_count, max_attempts) do
    next_status = if attempt_count >= max_attempts, do: "failed", else: "pending"

    Repo.update_all(
      from(n in RideNotification, where: n.id == ^notification_id),
      set: [push_status: next_status, updated_at: now]
    )

    if next_status == "failed", do: :failed, else: :pending
  end

  defp mark_exhausted_pending_as_failed(now, max_attempts) do
    {count, _} =
      Repo.update_all(
        from(n in RideNotification,
          where: n.push_status == "pending" and n.attempt_count >= ^max_attempts
        ),
        set: [push_status: "failed", updated_at: now]
      )

    count
  end

  defp push_payload(notification) do
    %{
      notification_id: notification.id,
      ride_id: notification.ride_id,
      recipient_user_id: notification.recipient_user_id,
      event_type: notification.event_type,
      payload: notification.payload
    }
  end

  defp push_client do
    Application.get_env(:liddr, :ride_push_client, Liddr.Rides.PushClient.Noop)
  end

  defp resolve_policy(attrs) do
    config = Application.get_env(:liddr, __MODULE__, [])

    %{
      limit:
        parse_int(
          get_value(attrs, :limit) || Keyword.get(config, :limit),
          @default_limit,
          1,
          @max_limit
        ),
      max_attempts:
        parse_int(
          get_value(attrs, :max_attempts) || Keyword.get(config, :max_attempts),
          @default_max_attempts,
          1,
          20
        ),
      retry_interval_seconds:
        parse_int(
          get_value(attrs, :retry_interval_seconds) ||
            Keyword.get(config, :retry_interval_seconds),
          @default_retry_interval_seconds,
          1,
          3_600
        )
    }
  end

  defp init_result(exhausted_count) do
    %{
      processed: 0,
      sent: 0,
      retry_scheduled: 0,
      failed: 0,
      skipped: 0,
      exhausted_marked_failed: exhausted_count,
      errors: []
    }
  end

  defp append_error(acc, reason) do
    %{acc | errors: [to_string(reason) | acc.errors] |> Enum.take(20)}
  end

  defp parse_int(value, default, min, max) when is_integer(value) do
    if value >= min and value <= max, do: value, else: default
  end

  defp parse_int(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parse_int(parsed, default, min, max)
      _ -> default
    end
  end

  defp parse_int(_value, default, _min, _max), do: default

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil
end
