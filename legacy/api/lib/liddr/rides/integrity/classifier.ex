defmodule Liddr.Rides.Integrity.Classifier do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Location.DriverLocation
  alias Liddr.Repo
  alias Liddr.Rides.Geo
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Rides.Ride

  @policy_version "ride_integrity_v1"
  @rider_no_show_reason_code "rider_no_show"
  @driver_justified_cancel_reason_codes ~w(vehicle_issue safety_concern emergency)

  def classify_rider_cancel(%Ride{} = ride, reason_code, now) do
    signals = rider_signals(ride, now)

    {chargeable, waiver_code} =
      cond do
        is_nil(ride.driver_id) ->
          {false, "unassigned_ride_cancel"}

        reason_code in ~w(safety_concern emergency) ->
          {false, "rider_emergency_or_safety"}

        rider_within_grace_window?(signals) ->
          {false, "rider_free_cancel_window"}

        rider_driver_late?(signals) ->
          {false, "driver_late"}

        rider_driver_location_stale?(signals) ->
          {false, "driver_location_stale"}

        reason_code == "driver_not_moving" and rider_driver_not_moving?(signals) ->
          {false, "driver_not_moving"}

        reason_code == "driver_not_moving" and rider_driver_moving_away?(signals) ->
          {false, "driver_moving_away"}

        reason_code == "driver_too_far" and rider_driver_too_far?(signals) ->
          {false, "driver_too_far"}

        true ->
          {true, nil}
      end

    base_payload(
      ride,
      now,
      "rider",
      "rider",
      reason_code,
      "cancellation",
      chargeable,
      waiver_code,
      signals
    )
  end

  def classify_driver_cancel(%Ride{} = ride, reason_code, now) do
    chargeable = reason_code not in @driver_justified_cancel_reason_codes

    base_payload(
      ride,
      now,
      "driver",
      "driver",
      reason_code,
      "cancellation",
      chargeable,
      if(chargeable, do: nil, else: "driver_justified_reason"),
      %{}
    )
  end

  def classify_rider_no_show(%Ride{} = ride, now, signals \\ %{}) do
    base_payload(
      ride,
      now,
      "driver",
      "rider",
      @rider_no_show_reason_code,
      "no_show",
      true,
      nil,
      signals
    )
  end

  defp base_payload(
         ride,
         now,
         actor_role,
         subject_role,
         reason_code,
         violation_type,
         chargeable,
         waiver_code,
         signals
       ) do
    %{
      "policy_version" => @policy_version,
      "evaluated_at" => now,
      "actor_role" => actor_role,
      "actor_user_id" => role_user_id(ride, actor_role),
      "subject_role" => subject_role,
      "subject_user_id" => role_user_id(ride, subject_role),
      "reason_code" => reason_code,
      "violation_type" => violation_type,
      "chargeable" => chargeable,
      "waiver_code" => waiver_code,
      "signals" => signals
    }
  end

  defp role_user_id(ride, "rider"), do: ride.rider_id
  defp role_user_id(ride, "driver"), do: ride.driver_id
  defp role_user_id(_ride, _role), do: nil

  defp rider_signals(%Ride{} = ride, now) do
    baseline_distance_m = metadata_integer(ride.metadata, "driver_distance_to_pickup_m_at_accept")

    promised_pickup_eta_s =
      metadata_integer(ride.metadata, "promised_pickup_eta_s_at_accept")

    accepted_elapsed_seconds = elapsed_seconds(ride.accepted_at, now)
    {current_distance_m, location_age_seconds} = distance_and_location_age(ride, now)

    %{
      "accepted_elapsed_seconds" => accepted_elapsed_seconds,
      "promised_pickup_eta_s_at_accept" => promised_pickup_eta_s,
      "pickup_distance_m_at_accept" => baseline_distance_m,
      "pickup_distance_m_now" => current_distance_m,
      "driver_location_age_seconds" => location_age_seconds
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
        Geo.haversine_distance_m(
          location.lat,
          location.lng,
          ride.pickup_lat,
          ride.pickup_lng
        )
        |> round()

      age_seconds = DateTime.diff(now, location.captured_at, :second)
      {distance_m, age_seconds}
    end
  end

  defp rider_within_grace_window?(signals) do
    elapsed = Map.get(signals, "accepted_elapsed_seconds")
    is_integer(elapsed) and elapsed <= Policy.rider_free_cancel_grace_seconds()
  end

  defp rider_driver_late?(signals) do
    elapsed = Map.get(signals, "accepted_elapsed_seconds")
    promised = Map.get(signals, "promised_pickup_eta_s_at_accept")

    is_integer(elapsed) and is_integer(promised) and
      elapsed >= promised + Policy.rider_driver_late_waiver_seconds()
  end

  defp rider_driver_location_stale?(signals) do
    age = Map.get(signals, "driver_location_age_seconds")
    not is_integer(age) or age > Policy.rider_driver_location_stale_seconds()
  end

  defp rider_driver_not_moving?(signals) do
    elapsed = Map.get(signals, "accepted_elapsed_seconds")
    delta = distance_delta(signals)

    is_integer(elapsed) and elapsed >= Policy.rider_no_progress_elapsed_seconds() and
      is_integer(delta) and delta >= Policy.rider_no_progress_delta_m()
  end

  defp rider_driver_moving_away?(signals) do
    elapsed = Map.get(signals, "accepted_elapsed_seconds")
    delta = distance_delta(signals)

    is_integer(elapsed) and elapsed >= Policy.rider_moving_away_elapsed_seconds() and
      is_integer(delta) and delta >= Policy.rider_moving_away_delta_m()
  end

  defp rider_driver_too_far?(signals) do
    current = Map.get(signals, "pickup_distance_m_now")
    is_integer(current) and current >= Policy.rider_pickup_far_distance_m()
  end

  defp distance_delta(signals) do
    now_distance = Map.get(signals, "pickup_distance_m_now")
    accepted_distance = Map.get(signals, "pickup_distance_m_at_accept")

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
end
