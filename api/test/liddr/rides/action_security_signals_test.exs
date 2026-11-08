defmodule Liddr.Rides.ActionSecuritySignalsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Liddr.Rides.ActionSecuritySignals
  alias Liddr.TestSupport.FakeRedis

  setup do
    previous_policy = Application.get_env(:liddr, ActionSecuritySignals)
    previous_mode = System.get_env("SECURITY_MODE")

    on_exit(fn ->
      restore_app_env(ActionSecuritySignals, previous_policy)
      restore_system_env("SECURITY_MODE", previous_mode)
    end)

    FakeRedis.reset!()
    :ok
  end

  test "observe mode allows IP hotspot signals" do
    System.put_env("SECURITY_MODE", "observe")
    put_policy!(enforce_ip_on_enforce_mode: true)

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 1001, %{
               ip: "10.10.10.10",
               device: nil
             })

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 1002, %{
               ip: "10.10.10.10",
               device: nil
             })
  end

  test "enforce mode keeps IP hotspots soft by default" do
    System.put_env("SECURITY_MODE", "enforce")
    put_policy!(enforce_ip_on_enforce_mode: false)

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 2001, %{
               ip: "172.16.1.20",
               device: nil
             })

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 2002, %{
               ip: "172.16.1.20",
               device: nil
             })
  end

  test "enforce mode can block IP hotspot when explicitly enabled" do
    System.put_env("SECURITY_MODE", "enforce")
    put_policy!(enforce_ip_on_enforce_mode: true)

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 3001, %{
               ip: "192.168.10.25",
               device: nil
             })

    assert {:error, :ride_action_secondary_rate_limited} =
             ActionSecuritySignals.enforce(:ride_request, 3002, %{
               ip: "192.168.10.25",
               device: nil
             })
  end

  test "enforce mode blocks abnormal single-device multi-account activity" do
    System.put_env("SECURITY_MODE", "enforce")
    put_policy!(enforce_ip_on_enforce_mode: false)

    assert :ok =
             ActionSecuritySignals.enforce(:ride_request, 4001, %{
               ip: "127.0.0.1",
               device: "android-device-shared"
             })

    assert {:error, :ride_action_secondary_rate_limited} =
             ActionSecuritySignals.enforce(:ride_request, 4002, %{
               ip: "127.0.0.1",
               device: "android-device-shared"
             })
  end

  test "repeated hotspot detections are log-suppressed within the log window" do
    System.put_env("SECURITY_MODE", "observe")

    put_policy!(
      ip_max_events: 1,
      ip_max_distinct_users: 1,
      device_max_events: 50,
      device_max_distinct_users: 50,
      log_ttl_seconds: 600
    )

    log =
      capture_log(fn ->
        assert :ok = ActionSecuritySignals.enforce(:ride_request, 5001, %{ip: "10.0.0.9"})
        assert :ok = ActionSecuritySignals.enforce(:ride_request, 5002, %{ip: "10.0.0.9"})
      end)

    assert log =~ "abnormal action pattern detected"
    assert length(Regex.scan(~r/abnormal action pattern detected/, log)) == 1
  end

  defp put_policy!(overrides) do
    Application.put_env(
      :liddr,
      ActionSecuritySignals,
      Keyword.merge(
        [
          enabled: true,
          ip_window_seconds: 600,
          ip_max_events: 2,
          ip_max_distinct_users: 2,
          device_window_seconds: 600,
          device_max_events: 50,
          device_max_distinct_users: 2,
          log_ttl_seconds: 60,
          enforce_ip_on_enforce_mode: false,
          redis_module: FakeRedis
        ],
        overrides
      )
    )
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:liddr, key)
  defp restore_app_env(key, value), do: Application.put_env(:liddr, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
