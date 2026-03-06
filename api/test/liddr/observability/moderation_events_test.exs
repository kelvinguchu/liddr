defmodule Liddr.Observability.ModerationEventsTest do
  use ExUnit.Case, async: true

  alias Liddr.Observability.ModerationEvents

  test "emits dispute create success telemetry" do
    handler_id = attach_handler!([:liddr, :disputes, :create, :success])

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    ModerationEvents.dispute_create_success(%{
      dispute_type: "fare_dispute",
      reporter_user_id: 100
    })

    assert_receive {:telemetry_event, [:liddr, :disputes, :create, :success], %{count: 1},
                    metadata}

    assert metadata.dispute_type == "fare_dispute"
    assert metadata.reporter_user_id == "100"
  end

  test "normalizes unknown metadata values safely" do
    handler_id = attach_handler!([:liddr, :moderation, :report, :triage, :success])

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    ModerationEvents.report_triage_success(%{
      "status" => "",
      "unexpected_key" => "ignored"
    })

    assert_receive {:telemetry_event, [:liddr, :moderation, :report, :triage, :success],
                    %{count: 1}, metadata}

    assert metadata.status == "unknown"
    assert metadata.unknown == "ignored"
  end

  defp attach_handler!(event_name) do
    handler_id = "moderation-events-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event_name,
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        self()
      )

    handler_id
  end
end
