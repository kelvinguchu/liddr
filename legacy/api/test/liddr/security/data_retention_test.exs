defmodule Liddr.Security.DataRetentionTest do
  use Liddr.DataCase, async: false

  alias Liddr.Accounts.User
  alias Liddr.Auth.AuthChallenge
  alias Liddr.Idempotency.Request
  alias Liddr.Repo
  alias Liddr.Security.DataRetention
  alias Liddr.Subscriptions.WebhookEvent

  test "purges records beyond configured retention windows" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    user = Repo.insert!(%User{phone: unique_phone()})

    previous_policy = Application.get_env(:liddr, DataRetention, [])

    Application.put_env(
      :liddr,
      DataRetention,
      auth_challenges_ttl_days: 7,
      idempotency_ttl_days: 30,
      webhook_events_ttl_days: 180
    )

    on_exit(fn -> Application.put_env(:liddr, DataRetention, previous_policy) end)

    stale_challenge =
      Repo.insert!(%AuthChallenge{
        user_id: user.id,
        provider: "phone_otp",
        identity_value: user.phone,
        purpose: "login",
        channel: "sms",
        code_hash: String.duplicate("a", 64),
        expires_at: DateTime.add(now, -(9 * 86_400), :second),
        consumed_at: DateTime.add(now, -(8 * 86_400), :second)
      })

    recent_challenge =
      Repo.insert!(%AuthChallenge{
        user_id: user.id,
        provider: "phone_otp",
        identity_value: user.phone,
        purpose: "login",
        channel: "sms",
        code_hash: String.duplicate("b", 64),
        expires_at: DateTime.add(now, 60, :second)
      })

    stale_request =
      Repo.insert!(%Request{
        user_id: user.id,
        operation: "test.op",
        idempotency_key: "idem-#{System.unique_integer([:positive])}",
        request_hash: String.duplicate("c", 64),
        response_status: 200,
        response_body: %{"ok" => true},
        completed_at: DateTime.add(now, -(31 * 86_400), :second)
      })

    recent_request =
      Repo.insert!(%Request{
        user_id: user.id,
        operation: "test.op",
        idempotency_key: "idem-#{System.unique_integer([:positive])}",
        request_hash: String.duplicate("d", 64),
        response_status: 200,
        response_body: %{"ok" => true},
        completed_at: DateTime.add(now, -(5 * 86_400), :second)
      })

    stale_webhook =
      Repo.insert!(%WebhookEvent{
        provider: "mpesa",
        event_type: "stk_callback",
        external_ref: "old-#{System.unique_integer([:positive])}",
        payload: %{"status" => "old"},
        processed_at: DateTime.add(now, -(181 * 86_400), :second),
        inserted_at: DateTime.add(now, -(181 * 86_400), :second)
      })

    recent_webhook =
      Repo.insert!(%WebhookEvent{
        provider: "mpesa",
        event_type: "stk_callback",
        external_ref: "new-#{System.unique_integer([:positive])}",
        payload: %{"status" => "new"},
        processed_at: now
      })

    result = DataRetention.run(now)

    assert result.auth_challenges_deleted >= 1
    assert result.idempotency_requests_deleted >= 1
    assert result.webhook_events_deleted >= 1
    refute Repo.get(AuthChallenge, stale_challenge.id)
    assert Repo.get(AuthChallenge, recent_challenge.id)
    refute Repo.get(Request, stale_request.id)
    assert Repo.get(Request, recent_request.id)
    refute Repo.get(WebhookEvent, stale_webhook.id)
    assert Repo.get(WebhookEvent, recent_webhook.id)
  end

  defp unique_phone do
    "2547#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(8, "0") |> String.slice(-8, 8)}"
  end
end
