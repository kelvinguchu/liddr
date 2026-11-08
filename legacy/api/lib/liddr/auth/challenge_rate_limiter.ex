defmodule Liddr.Auth.ChallengeRateLimiter do
  import Ecto.Query

  alias Liddr.Auth.AuthChallenge
  alias Liddr.Auth.Input
  alias Liddr.Repo

  @defaults %{
    cooldown_seconds: 30,
    identity_window_seconds: 900,
    identity_max_requests: 5,
    ip_window_seconds: 900,
    ip_max_requests: 60,
    device_window_seconds: 900,
    device_max_requests: 40
  }

  def enforce(provider, identity_value, purpose, meta, now) do
    policy = policy()

    with :ok <- enforce_cooldown(provider, identity_value, purpose, now, policy),
         :ok <- enforce_identity_window(provider, identity_value, now, policy),
         :ok <- enforce_ip_window(Input.get_value(meta, :ip), now, policy),
         :ok <- enforce_device_window(Input.get_value(meta, :device), now, policy) do
      :ok
    end
  end

  defp enforce_cooldown(provider, identity_value, purpose, now, policy) do
    cooldown_cutoff = DateTime.add(now, -policy.cooldown_seconds, :second)

    recent? =
      Repo.exists?(
        from ac in AuthChallenge,
          where:
            ac.provider == ^provider and ac.identity_value == ^identity_value and
              ac.purpose == ^purpose and ac.inserted_at >= ^cooldown_cutoff
      )

    if recent?, do: {:error, :challenge_rate_limited}, else: :ok
  end

  defp enforce_identity_window(provider, identity_value, now, policy) do
    identity_cutoff = DateTime.add(now, -policy.identity_window_seconds, :second)

    count =
      Repo.aggregate(
        from(ac in AuthChallenge,
          where:
            ac.provider == ^provider and ac.identity_value == ^identity_value and
              ac.inserted_at >= ^identity_cutoff
        ),
        :count,
        :id
      )

    if count >= policy.identity_max_requests, do: {:error, :challenge_rate_limited}, else: :ok
  end

  defp enforce_ip_window(ip, _now, _policy) when ip in [nil, ""], do: :ok

  defp enforce_ip_window(ip, now, policy) when is_binary(ip) do
    ip_cutoff = DateTime.add(now, -policy.ip_window_seconds, :second)

    count =
      Repo.aggregate(
        from(ac in AuthChallenge,
          where: ac.requested_by_ip == ^ip and ac.inserted_at >= ^ip_cutoff
        ),
        :count,
        :id
      )

    if count >= policy.ip_max_requests, do: {:error, :challenge_rate_limited}, else: :ok
  end

  defp enforce_device_window(device, _now, _policy) when device in [nil, ""], do: :ok

  defp enforce_device_window(device, now, policy) when is_binary(device) do
    device_cutoff = DateTime.add(now, -policy.device_window_seconds, :second)

    count =
      Repo.aggregate(
        from(ac in AuthChallenge,
          where: ac.requested_by_device == ^device and ac.inserted_at >= ^device_cutoff
        ),
        :count,
        :id
      )

    if count >= policy.device_max_requests, do: {:error, :challenge_rate_limited}, else: :ok
  end

  defp policy do
    configured = Application.get_env(:liddr, __MODULE__, [])

    %{
      cooldown_seconds: resolve_int(configured, :cooldown_seconds, 1, 900),
      identity_window_seconds: resolve_int(configured, :identity_window_seconds, 60, 86_400),
      identity_max_requests: resolve_int(configured, :identity_max_requests, 1, 500),
      ip_window_seconds: resolve_int(configured, :ip_window_seconds, 60, 86_400),
      ip_max_requests: resolve_int(configured, :ip_max_requests, 1, 10_000),
      device_window_seconds: resolve_int(configured, :device_window_seconds, 60, 86_400),
      device_max_requests: resolve_int(configured, :device_max_requests, 1, 10_000)
    }
  end

  defp resolve_int(configured, key, min, max) do
    value =
      case Keyword.get(configured, key, Map.fetch!(@defaults, key)) do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(String.trim(value)) do
            {parsed, ""} -> parsed
            _ -> Map.fetch!(@defaults, key)
          end

        _ ->
          Map.fetch!(@defaults, key)
      end

    if value < min or value > max, do: Map.fetch!(@defaults, key), else: value
  end
end
