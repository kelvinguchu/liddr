defmodule Liddr.Rides.ActionRateLimiter do
  import Ecto.Query

  alias Liddr.Location.Redis
  alias Liddr.Repo
  alias Liddr.Rides.Ride
  alias Liddr.Rides.RideMessage

  @defaults %{
    ride_request_window_seconds: 600,
    ride_request_max_requests: 8,
    rider_cancel_window_seconds: 1800,
    rider_cancel_max_actions: 5,
    driver_cancel_window_seconds: 1800,
    driver_cancel_max_actions: 5,
    driver_no_show_window_seconds: 1800,
    driver_no_show_max_actions: 4,
    message_send_window_seconds: 60,
    message_send_max_messages: 20
  }

  def enforce_rider_request(user_id, now \\ current_time()) do
    policy = policy()

    count =
      case increment_request_counter(policy, user_id) do
        {:ok, value} -> value
        :error -> request_count_from_db(user_id, now, policy)
      end

    if count >= policy.ride_request_max_requests,
      do: {:error, :ride_request_rate_limited},
      else: :ok
  end

  def enforce_rider_cancel(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.rider_cancel_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Ride,
          where:
            r.rider_id == ^user_id and r.cancelled_by_user_id == ^user_id and
              not is_nil(r.cancelled_at) and r.cancelled_at >= ^cutoff
        ),
        :count,
        :id
      )

    if count >= policy.rider_cancel_max_actions,
      do: {:error, :rider_cancel_rate_limited},
      else: :ok
  end

  def enforce_driver_cancel(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.driver_cancel_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Ride,
          where:
            r.driver_id == ^user_id and r.cancelled_by_user_id == ^user_id and
              not is_nil(r.cancelled_at) and r.cancelled_at >= ^cutoff
        ),
        :count,
        :id
      )

    if count >= policy.driver_cancel_max_actions,
      do: {:error, :driver_cancel_rate_limited},
      else: :ok
  end

  def enforce_driver_no_show(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.driver_no_show_window_seconds, :second)

    count =
      Repo.aggregate(
        from(r in Ride,
          where:
            r.driver_id == ^user_id and not is_nil(r.no_show_marked_at) and
              r.no_show_marked_at >= ^cutoff
        ),
        :count,
        :id
      )

    if count >= policy.driver_no_show_max_actions,
      do: {:error, :driver_no_show_rate_limited},
      else: :ok
  end

  def enforce_message_send(user_id, now \\ current_time()) do
    policy = policy()
    cutoff = DateTime.add(now, -policy.message_send_window_seconds, :second)

    count =
      Repo.aggregate(
        from(m in RideMessage,
          where: m.sender_user_id == ^user_id and m.inserted_at >= ^cutoff
        ),
        :count,
        :id
      )

    if count >= policy.message_send_max_messages,
      do: {:error, :ride_message_rate_limited},
      else: :ok
  end

  defp policy do
    configured = Application.get_env(:liddr, __MODULE__, [])

    %{
      ride_request_window_seconds:
        resolve_int(configured, :ride_request_window_seconds, 10, 86_400),
      ride_request_max_requests: resolve_int(configured, :ride_request_max_requests, 1, 10_000),
      rider_cancel_window_seconds:
        resolve_int(configured, :rider_cancel_window_seconds, 10, 86_400),
      rider_cancel_max_actions: resolve_int(configured, :rider_cancel_max_actions, 1, 10_000),
      driver_cancel_window_seconds:
        resolve_int(configured, :driver_cancel_window_seconds, 10, 86_400),
      driver_cancel_max_actions: resolve_int(configured, :driver_cancel_max_actions, 1, 10_000),
      driver_no_show_window_seconds:
        resolve_int(configured, :driver_no_show_window_seconds, 10, 86_400),
      driver_no_show_max_actions: resolve_int(configured, :driver_no_show_max_actions, 1, 10_000),
      message_send_window_seconds:
        resolve_int(configured, :message_send_window_seconds, 5, 86_400),
      message_send_max_messages: resolve_int(configured, :message_send_max_messages, 1, 10_000),
      redis_module: Keyword.get(configured, :redis_module, Redis)
    }
  end

  defp increment_request_counter(policy, user_id) do
    ttl = Integer.to_string(policy.ride_request_window_seconds)
    key = "ride:rate:v1:request:user:#{user_id}"

    case policy.redis_module.pipeline([["INCR", key], ["EXPIRE", key, ttl]]) do
      {:ok, [count, _expire]} -> parse_counter(count)
      _ -> :error
    end
  end

  defp request_count_from_db(user_id, now, policy) do
    cutoff = DateTime.add(now, -policy.ride_request_window_seconds, :second)

    Repo.aggregate(
      from(r in Ride,
        where: r.rider_id == ^user_id and r.requested_at >= ^cutoff
      ),
      :count,
      :id
    )
  end

  defp resolve_int(configured, key, min, max) do
    value =
      case Keyword.get(configured, key, Map.fetch!(@defaults, key)) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int_or_nil(value)
        _ -> nil
      end

    value =
      if is_integer(value),
        do: value,
        else: Map.fetch!(@defaults, key)

    if value < min or value > max, do: Map.fetch!(@defaults, key), else: value
  end

  defp parse_int_or_nil(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_counter(value) when is_integer(value), do: {:ok, value}

  defp parse_counter(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_counter(_value), do: :error

  defp current_time, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
