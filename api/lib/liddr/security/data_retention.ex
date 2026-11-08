defmodule Liddr.Security.DataRetention do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Auth.AuthChallenge
  alias Liddr.Idempotency.Request
  alias Liddr.Repo
  alias Liddr.Subscriptions.WebhookEvent

  @event [:liddr, :security, :retention, :run]
  @default_auth_challenges_ttl_days 7
  @default_idempotency_ttl_days 30
  @default_webhook_events_ttl_days 180

  def run(now \\ DateTime.utc_now() |> DateTime.truncate(:second)) do
    policy = resolved_policy()

    auth_deleted = delete_expired_auth_challenges(now, policy.auth_challenges_ttl_days)
    idempotency_deleted = delete_completed_idempotency_requests(now, policy.idempotency_ttl_days)
    webhook_deleted = delete_old_webhook_events(now, policy.webhook_events_ttl_days)

    result = %{
      auth_challenges_deleted: auth_deleted,
      idempotency_requests_deleted: idempotency_deleted,
      webhook_events_deleted: webhook_deleted
    }

    :telemetry.execute(@event, %{count: 1}, Map.put(result, :source, "data_retention_worker"))
    result
  end

  defp delete_expired_auth_challenges(now, ttl_days) do
    cutoff = cutoff_for_days(now, ttl_days)

    from(c in AuthChallenge,
      where:
        (not is_nil(c.consumed_at) and c.consumed_at < ^cutoff) or
          c.expires_at < ^cutoff
    )
    |> Repo.delete_all()
    |> elem(0)
  end

  defp delete_completed_idempotency_requests(now, ttl_days) do
    cutoff = cutoff_for_days(now, ttl_days)

    from(r in Request,
      where: not is_nil(r.completed_at) and r.completed_at < ^cutoff
    )
    |> Repo.delete_all()
    |> elem(0)
  end

  defp delete_old_webhook_events(now, ttl_days) do
    cutoff = cutoff_for_days(now, ttl_days)

    from(e in WebhookEvent, where: e.inserted_at < ^cutoff)
    |> Repo.delete_all()
    |> elem(0)
  end

  defp resolved_policy do
    configured = Application.get_env(:liddr, __MODULE__, [])

    %{
      auth_challenges_ttl_days:
        resolve_int(configured, :auth_challenges_ttl_days, @default_auth_challenges_ttl_days),
      idempotency_ttl_days:
        resolve_int(configured, :idempotency_ttl_days, @default_idempotency_ttl_days),
      webhook_events_ttl_days:
        resolve_int(configured, :webhook_events_ttl_days, @default_webhook_events_ttl_days)
    }
  end

  defp resolve_int(configured, key, default) do
    case Keyword.get(configured, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp cutoff_for_days(now, ttl_days) do
    DateTime.add(now, -(ttl_days * 86_400), :second)
  end
end
