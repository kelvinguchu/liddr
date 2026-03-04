defmodule Liddr.Rides.Execution.PickupHealth do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Rides.Ride

  def evaluate(%Ride{} = ride, now) do
    baseline_distance_m = metadata_integer(ride.metadata, "driver_distance_to_pickup_m_at_accept")
    promised_pickup_eta_s = metadata_integer(ride.metadata, "promised_pickup_eta_s_at_accept")
    reassign_count = metadata_non_negative_integer(ride.metadata, "reassign_count", 0)
    accepted_elapsed_seconds = elapsed_seconds(ride.accepted_at, now)
    {distance_now_m, location_age_seconds} = distance_and_location_age(ride, now)
    distance_delta_m = distance_delta(distance_now_m, baseline_distance_m)

    flags = %{
      "driver_location_stale" =>
        not is_integer(location_age_seconds) or
          location_age_seconds > Policy.rider_driver_location_stale_seconds(),
      "driver_late" =>
        is_integer(accepted_elapsed_seconds) and is_integer(promised_pickup_eta_s) and
          accepted_elapsed_seconds >=
            promised_pickup_eta_s + Policy.rider_driver_late_waiver_seconds(),
      "driver_no_progress" =>
        is_integer(accepted_elapsed_seconds) and
          accepted_elapsed_seconds >= Policy.rider_no_progress_elapsed_seconds() and
          is_integer(distance_delta_m) and distance_delta_m >= Policy.rider_no_progress_delta_m(),
      "driver_moving_away" =>
        is_integer(accepted_elapsed_seconds) and
          accepted_elapsed_seconds >= Policy.rider_moving_away_elapsed_seconds() and
          is_integer(distance_delta_m) and distance_delta_m >= Policy.rider_moving_away_delta_m()
    }

    reason =
      cond do
        flags["driver_location_stale"] -> "driver_location_stale"
        flags["driver_moving_away"] -> "driver_moving_away"
        flags["driver_no_progress"] -> "driver_no_progress"
        flags["driver_late"] -> "driver_late"
        true -> nil
      end

    %{
      "signals" => %{
        "accepted_elapsed_seconds" => accepted_elapsed_seconds,
        "promised_pickup_eta_s_at_accept" => promised_pickup_eta_s,
        "pickup_distance_m_at_accept" => baseline_distance_m,
        "pickup_distance_m_now" => distance_now_m,
        "distance_delta_m_from_accept" => distance_delta_m,
        "driver_location_age_seconds" => location_age_seconds,
        "reassign_count" => reassign_count
      },
      "flags" => flags,
      "recommend_reassign" => Enum.any?(Map.values(flags), &(&1 == true)),
      "recommendation_reason_code" => reason,
      "timeouts" => timeout_signals(accepted_elapsed_seconds, reassign_count)
    }
  end

  defp distance_and_location_age(%Ride{driver_id: nil}, _now), do: {nil, nil}

  defp distance_and_location_age(%Ride{} = ride, now) do
    location =
      Repo.one(
        from dl in DriverLocation,
          where: dl.driver_id == ^ride.driver_id,
          select: dl
      )

    if is_nil(location) do
      {nil, nil}
    else
      distance_m =
        Geo.haversine_distance_m(location.lat, location.lng, ride.pickup_lat, ride.pickup_lng)
        |> round()

      age_seconds = DateTime.diff(now, location.captured_at, :second)
      {distance_m, age_seconds}
    end
  end

  defp distance_delta(now_distance, accepted_distance) do
    if is_integer(now_distance) and is_integer(accepted_distance),
      do: now_distance - accepted_distance,
      else: nil
  end

  defp elapsed_seconds(nil, _now), do: nil
  defp elapsed_seconds(%DateTime{} = ts, now), do: DateTime.diff(now, ts, :second)

  defp metadata_integer(%{} = metadata, key) do
    case Map.get(metadata, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp metadata_integer(_metadata, _key), do: nil

  defp metadata_non_negative_integer(metadata, key, default) do
    case metadata_integer(metadata, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp timeout_signals(accepted_elapsed_seconds, reassign_count) do
    reassign_after = Policy.pickup_auto_reassign_after_seconds()
    cancel_after = Policy.pickup_auto_cancel_after_seconds()
    min_reassign_count = Policy.pickup_auto_cancel_min_reassign_count()

    elapsed = if is_integer(accepted_elapsed_seconds), do: accepted_elapsed_seconds, else: -1

    %{
      "auto_reassign_enabled" => Policy.pickup_auto_reassign_enabled(),
      "auto_reassign_after_seconds" => reassign_after,
      "auto_reassign_due" => Policy.pickup_auto_reassign_enabled() and elapsed >= reassign_after,
      "auto_cancel_enabled" => Policy.pickup_auto_cancel_enabled(),
      "auto_cancel_after_seconds" => cancel_after,
      "auto_cancel_min_reassign_count" => min_reassign_count,
      "auto_cancel_due" =>
        Policy.pickup_auto_cancel_enabled() and elapsed >= cancel_after and
          reassign_count >= min_reassign_count
    }
  end
end
