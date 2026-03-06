defmodule Liddr.Rides.ActionRateLimiterTest do
  use ExUnit.Case, async: false

  alias Liddr.Rides.ActionRateLimiter
  alias Liddr.TestSupport.FakeRedis

  setup do
    previous_policy = Application.get_env(:liddr, ActionRateLimiter)

    on_exit(fn ->
      if is_nil(previous_policy) do
        Application.delete_env(:liddr, ActionRateLimiter)
      else
        Application.put_env(:liddr, ActionRateLimiter, previous_policy)
      end
    end)

    FakeRedis.reset!()
    :ok
  end

  test "enforce_rider_request uses redis counter when available" do
    Application.put_env(:liddr, ActionRateLimiter,
      ride_request_window_seconds: 600,
      ride_request_max_requests: 2,
      redis_module: FakeRedis
    )

    assert :ok = ActionRateLimiter.enforce_rider_request(1234)
    assert {:error, :ride_request_rate_limited} = ActionRateLimiter.enforce_rider_request(1234)
  end
end
