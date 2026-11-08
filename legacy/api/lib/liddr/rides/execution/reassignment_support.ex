defmodule Liddr.Rides.Execution.ReassignmentSupport do
  alias Liddr.Rides.Events
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Realtime

  def enrich_reassign_metadata(metadata, previous_driver_id, health, attrs, now) do
    reassign_count =
      metadata
      |> Map.get("reassign_count", 0)
      |> case do
        value when is_integer(value) and value >= 0 -> value
        _ -> 0
      end

    notes =
      attrs
      |> get_value(:reason)
      |> case do
        value when is_binary(value) and value != "" -> String.trim(value)
        _ -> nil
      end

    metadata
    |> Map.put("reassign_count", reassign_count + 1)
    |> Map.put("last_reassign_at", now)
    |> Map.put("last_reassign_driver_id", previous_driver_id)
    |> Map.put("last_reassign_reason_code", health["recommendation_reason_code"])
    |> maybe_put("last_reassign_notes", notes)
  end

  def status_signal_from_health(%{"flags" => flags}) when is_map(flags) do
    cond do
      flags["driver_location_stale"] == true -> :driver_offline_detected
      flags["driver_late"] == true -> :driver_delayed
      flags["driver_no_progress"] == true -> :driver_delayed
      flags["driver_moving_away"] == true -> :driver_delayed
      true -> nil
    end
  end

  def status_signal_from_health(_health), do: nil

  def record_status_signal_event(
        _ride_id,
        _actor_user_id,
        _previous_driver_id,
        nil,
        _health,
        _now
      ),
      do: :ok

  def record_status_signal_event(
        ride_id,
        actor_user_id,
        previous_driver_id,
        signal_event,
        health,
        now
      ) do
    Events.record_event(ride_id, signal_event, now,
      actor_user_id: actor_user_id,
      payload: %{
        "previous_driver_id" => previous_driver_id,
        "recommendation_reason_code" => health["recommendation_reason_code"],
        "signals" => health["signals"],
        "flags" => health["flags"]
      }
    )
    |> Shared.unwrap_or_rollback()
  end

  def broadcast_offer_withdrawn(_ride_id, nil), do: :ok

  def broadcast_offer_withdrawn(ride_id, offer) do
    Realtime.broadcast_offer_withdrawn(ride_id, offer, "rider_reassign")
  end

  def broadcast_status_signal(%{status_signal: nil}), do: :ok

  def broadcast_status_signal(%{status_signal: :driver_offline_detected} = payload) do
    Realtime.broadcast_driver_offline_detected(
      payload.ride,
      %{
        previous_driver_id: payload.previous_driver_id,
        recommendation_reason_code: payload.health["recommendation_reason_code"],
        pickup_health: payload.health
      },
      payload.previous_driver_id
    )
  end

  def broadcast_status_signal(%{status_signal: :driver_delayed} = payload) do
    Realtime.broadcast_driver_delayed(
      payload.ride,
      %{
        previous_driver_id: payload.previous_driver_id,
        recommendation_reason_code: payload.health["recommendation_reason_code"],
        pickup_health: payload.health
      },
      payload.previous_driver_id
    )
  end

  def get_reassign_trigger_reason(attrs) do
    case get_value(attrs, :reason) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> "manual_reassign"
    end
  end

  defp get_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp get_value(_attrs, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
