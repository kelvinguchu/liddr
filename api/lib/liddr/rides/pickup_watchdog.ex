defmodule Liddr.Rides.PickupWatchdog do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Cancellation
  alias Liddr.Rides.Execution.Reassignment
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Rides.Ride

  @max_limit 1_000
  @auto_reassign_reason "pickup_timeout_auto_reassign"
  @auto_cancel_reason "driver_not_moving"
  @auto_reassign_event_type "pickup_watchdog_auto_reassign"
  @auto_cancel_event_type "pickup_watchdog_auto_cancel"

  def auto_reassign_event_type, do: @auto_reassign_event_type
  def auto_cancel_event_type, do: @auto_cancel_event_type

  def run(attrs \\ %{}) do
    now = resolve_now(attrs)
    limit = resolve_limit(attrs)

    rides =
      Repo.all(
        from r in Ride,
          where:
            r.status in ["accepted", "driver_arriving"] and not is_nil(r.driver_id) and
              not is_nil(r.accepted_at) and r.accepted_at <= ^candidate_cutoff(now),
          order_by: [asc: r.accepted_at, asc: r.id],
          limit: ^limit
      )

    results = Enum.map(rides, &process_ride(&1, now))

    %{
      scanned: length(rides),
      auto_reassigned: count_results(results, :auto_reassigned),
      auto_cancelled: count_results(results, :auto_cancelled),
      skipped: count_results(results, :skipped),
      failed: count_results(results, :failed)
    }
  end

  defp process_ride(%Ride{} = ride, now) do
    with {:ok, %{health: health}} <- Reassignment.pickup_health(ride.rider_id, ride.id),
         true <- health["recommend_reassign"] == true do
      elapsed_seconds = get_in(health, ["signals", "accepted_elapsed_seconds"])
      reassign_count = get_in(health, ["signals", "reassign_count"]) || 0

      cond do
        auto_cancel_due?(elapsed_seconds, reassign_count) ->
          run_auto_cancel(ride, health, now)

        auto_reassign_due?(elapsed_seconds) ->
          run_auto_reassign(ride, health, now)

        true ->
          :skipped
      end
    else
      _ -> :skipped
    end
  end

  defp run_auto_reassign(ride, health, now) do
    case Reassignment.request_reassign(ride.rider_id, ride.id, %{
           "reason" => @auto_reassign_reason
         }) do
      {:ok, _updated_ride} ->
        _ =
          Events.record_event(ride.id, @auto_reassign_event_type, now,
            actor_user_id: ride.rider_id,
            payload: watchdog_payload(ride, health, @auto_reassign_reason)
          )

        :auto_reassigned

      {:error, _reason} ->
        :failed
    end
  end

  defp run_auto_cancel(ride, health, now) do
    case Cancellation.rider_cancel_ride(ride.rider_id, ride.id, %{"reason" => @auto_cancel_reason}) do
      {:ok, _cancelled_ride} ->
        _ =
          Events.record_event(ride.id, @auto_cancel_event_type, now,
            actor_user_id: ride.rider_id,
            payload: watchdog_payload(ride, health, @auto_cancel_reason)
          )

        :auto_cancelled

      {:error, _reason} ->
        :failed
    end
  end

  defp auto_reassign_due?(elapsed_seconds) do
    Policy.pickup_auto_reassign_enabled() and is_integer(elapsed_seconds) and
      elapsed_seconds >= Policy.pickup_auto_reassign_after_seconds()
  end

  defp auto_cancel_due?(elapsed_seconds, reassign_count) do
    Policy.pickup_auto_cancel_enabled() and is_integer(elapsed_seconds) and
      elapsed_seconds >= Policy.pickup_auto_cancel_after_seconds() and
      reassign_count >= Policy.pickup_auto_cancel_min_reassign_count()
  end

  defp candidate_cutoff(now) do
    DateTime.add(now, -min_watchdog_age_seconds(), :second)
  end

  defp min_watchdog_age_seconds do
    thresholds =
      []
      |> maybe_add_threshold(
        Policy.pickup_auto_reassign_enabled(),
        Policy.pickup_auto_reassign_after_seconds()
      )
      |> maybe_add_threshold(
        Policy.pickup_auto_cancel_enabled(),
        Policy.pickup_auto_cancel_after_seconds()
      )

    case thresholds do
      [] -> 300
      _ -> Enum.min(thresholds)
    end
  end

  defp maybe_add_threshold(list, true, value) when is_integer(value) and value > 0,
    do: [value | list]

  defp maybe_add_threshold(list, _enabled, _value), do: list

  defp resolve_now(attrs) do
    case get_value(attrs, :now) do
      %DateTime{} = dt -> DateTime.truncate(dt, :microsecond)
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp resolve_limit(attrs) do
    attrs
    |> get_value(:limit)
    |> parse_positive_integer()
    |> case do
      nil ->
        Policy.pickup_watchdog_limit()

      value ->
        value
    end
    |> clamp(1, @max_limit)
  end

  defp count_results(results, value), do: Enum.count(results, &(&1 == value))

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil

  defp watchdog_payload(ride, health, action_reason_code) do
    %{
      "action_reason_code" => action_reason_code,
      "watchdog" => %{
        "ride_id" => ride.id,
        "rider_id" => ride.rider_id,
        "driver_id" => ride.driver_id
      },
      "pickup_health" => %{
        "recommendation_reason_code" => health["recommendation_reason_code"],
        "flags" => health["flags"],
        "signals" => health["signals"],
        "timeouts" => health["timeouts"]
      }
    }
  end
end
