defmodule Liddr.Subscriptions.ReconciliationPolicyTest do
  use ExUnit.Case, async: true

  alias Liddr.Subscriptions.ReconciliationPolicy

  describe "resolve/1" do
    setup do
      previous = Application.get_env(:liddr, ReconciliationPolicy)

      Application.put_env(:liddr, ReconciliationPolicy,
        limit: 40,
        grace_seconds: 120,
        max_age_seconds: 2_400,
        max_attempts: 10,
        interval_seconds: 90,
        backoff_seconds: [60, 120, 180]
      )

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:liddr, ReconciliationPolicy)
        else
          Application.put_env(:liddr, ReconciliationPolicy, previous)
        end
      end)

      :ok
    end

    test "uses configured defaults when no overrides are provided" do
      assert ReconciliationPolicy.resolve(%{}) == %{
               limit: 40,
               grace_seconds: 120,
               max_age_seconds: 2_400,
               max_attempts: 10,
               interval_seconds: 90,
               backoff_seconds: [60, 120, 180]
             }
    end

    test "accepts v1 override keys" do
      assert ReconciliationPolicy.resolve(%{
               "limit" => "10",
               "grace_seconds" => "5",
               "max_age_seconds" => "3600"
             }) == %{
               limit: 10,
               grace_seconds: 5,
               max_age_seconds: 3_600,
               max_attempts: 10,
               interval_seconds: 90,
               backoff_seconds: [60, 120, 180]
             }
    end

    test "ignores invalid overrides and keeps runtime config values" do
      assert ReconciliationPolicy.resolve(%{
               "limit" => "-1",
               "grace_seconds" => "oops",
               "max_age_seconds" => "0",
               "backoff_seconds" => "abc"
             }) == %{
               limit: 40,
               grace_seconds: 120,
               max_age_seconds: 2_400,
               max_attempts: 10,
               interval_seconds: 90,
               backoff_seconds: [60, 120, 180]
             }
    end
  end
end
